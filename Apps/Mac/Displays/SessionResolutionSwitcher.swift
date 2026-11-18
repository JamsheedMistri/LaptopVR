import CoreGraphics

/// Switches the main display to a lower scaled resolution for the length of a session, so text
/// is large enough to read in a phone viewer, and switches back afterwards.
@MainActor
final class SessionResolutionSwitcher {
    private var original: (display: CGDirectDisplayID, mode: CGDisplayMode)?

    /// Scaled resolutions the display offers, largest first.
    static func options(for display: CGDirectDisplayID) -> [SessionResolution] {
        var seen = Set<SessionResolution>()
        return modes(for: display)
            .map { SessionResolution(width: $0.width, height: $0.height) }
            .filter { seen.insert($0).inserted }
            .sorted { $0.width > $1.width }
    }

    /// Switches `display` to `resolution`, or back to its own mode when `resolution` is nil.
    /// Does nothing if the display is already there.
    func apply(_ resolution: SessionResolution?, to display: CGDirectDisplayID) {
        if resolution == nil || original?.display != display {
            restore()
        }
        guard let resolution,
              let current = CGDisplayCopyDisplayMode(display),
              current.width != resolution.width || current.height != resolution.height,
              let target = Self.modes(for: display)
                  .filter({ $0.width == resolution.width && $0.height == resolution.height })
                  .max(by: { $0.refreshRate < $1.refreshRate })
        else { return }

        // A nil options dictionary scopes the change to this app: macOS reverts it by itself if
        // the app exits without restoring.
        if CGDisplaySetDisplayMode(display, target, nil) == .success, original == nil {
            original = (display, current)
        }
    }

    func restore() {
        guard let original else { return }
        CGDisplaySetDisplayMode(original.display, original.mode, nil)
        self.original = nil
    }

    /// HiDPI modes with the display's own aspect ratio.
    private static func modes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
              let current = CGDisplayCopyDisplayMode(display)
        else { return [] }

        let aspect = Double(current.width) / Double(current.height)
        return all.filter { mode in
            mode.isUsableForDesktopGUI()
                && mode.pixelWidth > mode.width
                && mode.width >= 960
                && abs(Double(mode.width) / Double(mode.height) - aspect) < 0.02
        }
    }
}
