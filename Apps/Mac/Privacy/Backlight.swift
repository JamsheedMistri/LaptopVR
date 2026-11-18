import CoreGraphics
import Foundation

/// Turns the built-in panel's backlight off and back on.
///
/// macOS has no public API for setting brightness, so this calls the private DisplayServices
/// framework (the same one the brightness keys use). At zero the MacBook backlight is fully off
/// but the display stays awake and keeps rendering, so screen capture is unaffected.
@MainActor
enum Backlight {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static let getBrightness: GetBrightness? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private static let setBrightness: SetBrightness? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()

    /// The level to return to is persisted, so a crash while the panel is dark is repaired on
    /// the next launch.
    private static let savedLevelKey = "privacy.savedBrightness"

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// True on Macs with a built-in panel whose brightness the private API can control.
    static var isAvailable: Bool {
        guard let display = builtInDisplay, let getBrightness, setBrightness != nil else { return false }
        var level: Float = 0
        return getBrightness(display, &level) == 0
    }

    static func turnOff() {
        guard let display = builtInDisplay, let getBrightness, let setBrightness else { return }
        if UserDefaults.standard.object(forKey: savedLevelKey) == nil {
            var level: Float = 0
            guard getBrightness(display, &level) == 0 else { return }
            UserDefaults.standard.set(level, forKey: savedLevelKey)
        }
        _ = setBrightness(display, 0)
    }

    /// Restores the level saved by `turnOff`. Safe to call when nothing was saved.
    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedLevelKey) as? Float else { return }
        UserDefaults.standard.removeObject(forKey: savedLevelKey)
        guard let display = builtInDisplay, let setBrightness else { return }
        _ = setBrightness(display, saved)
    }
}
