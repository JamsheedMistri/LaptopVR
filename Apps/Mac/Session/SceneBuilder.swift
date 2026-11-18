import CoreGraphics
import VRProtocol
import VRVideo

/// Turns the Mac's display arrangement into the scene the phone renders.
enum SceneBuilder {
    /// Gap between neighbouring screens, as a fraction of their separation.
    private static let spacing = 1.03

    /// Places each display relative to the main one, which is one unit wide at the origin. Sizes
    /// are proportional to points, so text is the same size on every screen.
    static func screens(for displays: [DisplayInfo]) -> [ScreenDescriptor] {
        guard let main = displays.first(where: \.isMain) ?? displays.first else { return [] }
        let unit = main.bounds.width

        return displays.map { display in
            ScreenDescriptor(
                id: display.streamID,
                name: display.name,
                isMain: display.id == main.id,
                centerX: (display.bounds.midX - main.bounds.midX) / unit * spacing,
                // Global display coordinates grow downward; the canvas grows upward.
                centerY: -(display.bounds.midY - main.bounds.midY) / unit * spacing,
                width: display.bounds.width / unit,
                height: display.bounds.height / unit
            )
        }
    }

    static func curvature(for preference: CurvePreference, screenCount: Int) -> Double {
        switch preference {
        case .flat: 0
        case .curved: 1
        case .automatic: screenCount > 1 ? 1 : 0
        }
    }
}

/// Chooses how many pixels to capture and encode for a display.
enum StreamSizing {
    /// Extra pixels beyond what the viewer resolves, so resampling on the phone stays sharp.
    private static let oversampling = 1.3
    /// Sizes snap to multiples of this, so small zoom changes do not reconfigure the encoder.
    private static let step = 160.0

    static func size(
        for display: DisplayInfo,
        angularWidthDegrees: Double,
        pixelsPerDegree: Double,
        preference: ResolutionPreference,
        codec: VideoCodec
    ) -> (width: Int, height: Int) {
        let nativeWidth = Double(display.pixelWidth)
        let aspect = display.bounds.height / display.bounds.width

        var width: Double
        switch preference {
        case .native:
            width = nativeWidth
        case .standard:
            width = display.bounds.width
        case .automatic:
            let resolvable = angularWidthDegrees * pixelsPerDegree * oversampling
            width = max((resolvable / step).rounded(.up) * step, 960)
        }
        // Hardware encoders top out around 4K wide; more would not be visible anyway.
        width = min(width, nativeWidth, 4096)

        // Encoders need even dimensions.
        func even(_ width: Double) -> (width: Int, height: Int) {
            let evenWidth = max(Int(width / 2) * 2, 2)
            return (evenWidth, max(Int((Double(evenWidth) * aspect / 2).rounded()) * 2, 2))
        }

        var size = even(width)
        // A tall display can still be more than the encoder takes in one frame.
        while size.width > 640,
              VideoEncoderLimits.maxFramesPerSecond(width: size.width, height: size.height, codec: codec) == nil {
            size = even(Double(size.width - 32))
        }
        return size
    }

    /// Frames per second to encode a display at: no more than it refreshes, and no more than
    /// the encoder accepts for frames of this size.
    static func framesPerSecond(
        for display: DisplayInfo, size: (width: Int, height: Int), codec: VideoCodec, limit: Int
    ) -> Int {
        var rate = limit
        if display.refreshRate >= 1 {
            rate = min(rate, Int(display.refreshRate.rounded()))
        }
        if let encodable = VideoEncoderLimits.maxFramesPerSecond(width: size.width, height: size.height, codec: codec) {
            rate = min(rate, encodable)
        }
        return max(rate, 1)
    }
}
