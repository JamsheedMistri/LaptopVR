import UIKit

/// The physical size of the iPhone's pixels, which the lens geometry is measured against.
@MainActor
enum DisplayMetrics {
    /// iOS does not report pixel density, so it is looked up from the panel's resolution.
    /// Every iPhone not listed here has 460 pixels per inch.
    static func pixelsPerMeter(of screen: UIScreen) -> Float {
        let size = screen.nativeBounds.size
        let pixelsPerInch: Float = switch (Int(min(size.width, size.height)), Int(max(size.width, size.height))) {
        case (750, 1334), (828, 1792): 326
        case (1080, 2340): 476
        case (1125, 2436), (1242, 2688): 458
        default: 460
        }
        return pixelsPerInch / 0.0254
    }

    /// The screen the app is on.
    static var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}
