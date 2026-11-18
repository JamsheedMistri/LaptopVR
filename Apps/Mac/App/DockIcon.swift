import AppKit
import SwiftUI

/// Shows the app in the Dock while one of its real windows is open, and only then, so a window
/// that gets buried can be found again. The rest of the time the app lives in the menu bar.
///
/// Only windows handed to `track` count. The menu bar popover and the privacy covers are never
/// handed over.
@MainActor
final class DockIcon {
    static let shared = DockIcon()

    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// A minimized window is not visible, but it is still open and sits in the Dock.
    private var minimized: Set<ObjectIdentifier> = []
    private var isShown = false

    /// Counts `window` from now on. It is kept for the life of the app, as the windows this is
    /// used for are.
    func track(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard windows[key] == nil else { return }
        windows[key] = window

        observe(NSWindow.didBecomeKeyNotification, of: window) { _ in }
        observe(NSWindow.willMiniaturizeNotification, of: window) { $0.minimized.insert(key) }
        observe(NSWindow.didDeminiaturizeNotification, of: window) { $0.minimized.remove(key) }
        observe(NSWindow.willCloseNotification, of: window) { $0.minimized.remove(key) }
        refreshSoon()
    }

    private func observe(
        _ name: Notification.Name, of window: NSWindow, change: @escaping @MainActor (DockIcon) -> Void
    ) {
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                change(DockIcon.shared)
                DockIcon.shared.refreshSoon()
            }
        }
    }

    /// Later rather than now: a window that is about to close is still visible.
    private func refreshSoon() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    private func refresh() {
        let wanted = windows.contains { key, window in window.isVisible || minimized.contains(key) }
        guard wanted != isShown else { return }
        isShown = wanted

        if wanted {
            NSApp.setActivationPolicy(.regular)
            // A window has just opened, so come forward the way a regular app does.
            NSApp.activate()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension View {
    /// Shows the Dock icon for as long as the window this view is in stays open.
    func showsDockIconWhileOpen() -> some View {
        background(DockIconWindowFinder())
    }
}

/// Hands the window a SwiftUI view ends up in to `DockIcon`.
private struct DockIconWindowFinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DockIcon.shared.track(window)
            }
        }
    }
}
