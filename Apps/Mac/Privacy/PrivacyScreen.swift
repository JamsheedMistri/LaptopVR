import AppKit
import SwiftUI

/// Hides the desktop from anyone looking at the Mac while it is being viewed in the headset.
///
/// Two independent layers: the backlight is switched off, and a cover window sits on top of every
/// physical screen. The cover is left out of the app's own capture, so the headset still sees the
/// desktop underneath; anyone who turns the brightness back up sees the cover instead.
@MainActor
final class PrivacyScreen {
    struct Appearance: Equatable {
        var style: CoverStyle
        var imagePath: String?
        /// Shortcut that reveals the screen, shown on the cover.
        var revealHint: String
    }

    private var covers: [CGDirectDisplayID: NSWindow] = [:]
    private var appearance: Appearance?
    private var backlightIsOff = false

    /// Window identifiers to exclude from screen capture.
    var coverWindowIDs: [CGWindowID] {
        covers.values.map { CGWindowID($0.windowNumber) }.sorted()
    }

    func apply(mode: PrivacyMode, appearance: Appearance, displays: [DisplayInfo]) {
        if mode.usesBacklight {
            // Only on the transition, so a later refresh does not undo the brightness key.
            if !backlightIsOff {
                Backlight.turnOff()
                backlightIsOff = true
            }
        } else if backlightIsOff {
            Backlight.restore()
            backlightIsOff = false
        }

        // Virtual monitors have no glass to cover.
        let physical = mode.usesCover ? displays.filter { !$0.isVirtual } : []
        let wanted = Set(physical.map(\.id))

        for (id, window) in covers where !wanted.contains(id) {
            window.orderOut(nil)
            covers[id] = nil
        }
        for display in physical {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else { continue }
            let existing = covers[display.id]
            let window = existing ?? makeCover()
            if existing == nil || appearance != self.appearance {
                window.contentView = NSHostingView(rootView: CoverView(appearance: appearance))
            }
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
            window.orderFrontRegardless()
            covers[display.id] = window
        }
        self.appearance = appearance
    }

    func clear() {
        covers.values.forEach { $0.orderOut(nil) }
        covers = [:]
        if backlightIsOff {
            Backlight.restore()
            backlightIsOff = false
        }
    }

    private func makeCover() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        // Declared non-opaque although it draws solid black: an opaque window on top would make
        // the window server report everything beneath as occluded, and apps stop rendering
        // windows they believe nobody can see.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct CoverView: View {
    let appearance: PrivacyScreen.Appearance

    var body: some View {
        ZStack {
            Color.black

            switch appearance.style {
            case .black:
                EmptyView()
            case .image:
                if let path = appearance.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            case .logo:
                VStack(spacing: 28) {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180)
                    Text("This Mac is being used in LaptopVR")
                        .font(.title2.weight(.medium))
                    if !appearance.revealHint.isEmpty {
                        Text("Press \(appearance.revealHint) to show the screen")
                            .font(.body)
                            .opacity(0.6)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .ignoresSafeArea()
        .clipped()
    }
}
