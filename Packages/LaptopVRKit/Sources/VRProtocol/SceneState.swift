import Foundation

/// How screens respond to head movement.
public enum ViewMode: String, Codable, Sendable, CaseIterable {
    /// Screens stay fixed in space, like real monitors.
    case anchored
    /// Screens are dragged along when you look past their edge, so they never leave your view.
    case follow
}

public struct RGBColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// What surrounds the screens.
public struct EnvironmentSettings: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case solid, gradient, image, passthrough
    }

    public var kind: Kind
    /// Solid colour, or the top of the gradient.
    public var primaryColor: RGBColor
    /// Bottom of the gradient.
    public var secondaryColor: RGBColor
    /// Identifier of an image previously sent as an asset message.
    public var imageAssetID: String?
    /// 0 shows the image or camera at full brightness, 1 is black.
    public var dimming: Double

    public init(
        kind: Kind = .solid,
        primaryColor: RGBColor = RGBColor(red: 0.02, green: 0.02, blue: 0.03),
        secondaryColor: RGBColor = RGBColor(red: 0.10, green: 0.11, blue: 0.16),
        imageAssetID: String? = nil,
        dimming: Double = 0.35
    ) {
        self.kind = kind
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.imageAssetID = imageAssetID
        self.dimming = dimming
    }
}

/// One screen in the scene. Position and size are in canvas units, where the main screen is one
/// unit wide and centred on the origin; x grows to the right and y grows upward.
public struct ScreenDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// Also the stream identifier of this screen's video.
    public var id: UInt16
    public var name: String
    public var isMain: Bool
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double

    public init(id: UInt16, name: String, isMain: Bool, centerX: Double, centerY: Double, width: Double, height: Double) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
}

/// Everything the phone needs to lay out the scene. The Mac owns this and resends it on any change;
/// the phone owns head pose, and reports it as `ViewPose` so the Mac can record the view.
public struct SceneState: Codable, Sendable, Equatable {
    public var sessionActive: Bool
    public var screens: [ScreenDescriptor]
    /// Screen that recentering puts straight ahead.
    public var focusedScreen: UInt16
    public var mode: ViewMode
    /// Angular width of the main screen. This is the zoom control.
    public var screenAngleDegrees: Double
    /// Apparent distance of the screens, which sets stereo depth.
    public var distanceMeters: Double
    /// 0 is a flat wall, 1 wraps the screens around the viewer at constant distance.
    public var curvature: Double
    public var environment: EnvironmentSettings
    public var showStats: Bool
    /// The Mac is recording the view in passthrough, so the phone should send what its camera
    /// sees.
    public var sharesCamera: Bool

    public init(
        sessionActive: Bool = false,
        screens: [ScreenDescriptor] = [],
        focusedScreen: UInt16 = 0,
        mode: ViewMode = .anchored,
        screenAngleDegrees: Double = SceneState.defaultScreenAngle,
        distanceMeters: Double = 1.5,
        curvature: Double = 0,
        environment: EnvironmentSettings = EnvironmentSettings(),
        showStats: Bool = false,
        sharesCamera: Bool = false
    ) {
        self.sessionActive = sessionActive
        self.screens = screens
        self.focusedScreen = focusedScreen
        self.mode = mode
        self.screenAngleDegrees = screenAngleDegrees
        self.distanceMeters = distanceMeters
        self.curvature = curvature
        self.environment = environment
        self.showStats = showStats
        self.sharesCamera = sharesCamera
    }

    public static let defaultScreenAngle = 100.0
    public static let cinemaScreenAngle = 55.0
    public static let screenAngleRange = 25.0...170.0
    public static let distanceRange = 0.5...6.0
}
