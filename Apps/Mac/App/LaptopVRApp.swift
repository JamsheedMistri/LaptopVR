import AppKit
import SwiftUI

@main
struct LaptopVRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(model: AppModel.shared)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: AppModel.shared)
                .showsDockIconWhileOpen()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [any DispatchSourceSignal] = []
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.launch()
        restoreMacOnSignals()
        if !model.settings.general.hasCompletedOnboarding {
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.restoreMac()
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: WelcomeView(model: AppModel.shared) { [weak window] in
                window?.close()
            })
            window.contentViewController = content
            // SwiftUI would otherwise size the window after it is placed, growing it upwards.
            window.setContentSize(content.view.fittingSize)
            DockIcon.shared.track(window)
            welcomeWindow = window
        }
        if let window = welcomeWindow, !window.isVisible {
            centerOnScreen(window)
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    /// `NSWindow.center()` deliberately sits above the middle; this is the exact middle.
    private func centerOnScreen(_ window: NSWindow) {
        guard let area = (NSScreen.main ?? window.screen)?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(
            x: (area.midX - window.frame.width / 2).rounded(),
            y: (area.midY - window.frame.height / 2).rounded()
        ))
    }

    /// A session leaves the backlight off and covers on the screens. Being killed from the
    /// terminal or at logout must not leave the Mac that way.
    private func restoreMacOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            // The default action would end the process before the handler runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppModel.shared.restoreMac()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
