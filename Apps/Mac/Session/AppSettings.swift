import Foundation
import VRProtocol

enum CurvePreference: String, Codable, CaseIterable {
    /// Flat for a single screen, wrapped around the viewer for several.
    case automatic
    case flat
    case curved
}

enum PrivacyMode: String, Codable, CaseIterable {
    case off, backlight, cover, both

    var usesBacklight: Bool { self == .backlight || self == .both }
    var usesCover: Bool { self == .cover || self == .both }

    var title: String {
        switch self {
        case .off: "Off"
        case .backlight: "Backlight"
        case .cover: "Cover"
        case .both: "Both"
        }
    }
}

enum CoverStyle: String, Codable, CaseIterable {
    case black, logo, image
}

enum ResolutionPreference: String, Codable, CaseIterable {
    /// As many pixels as the viewer can resolve at the current zoom.
    case automatic
    /// One pixel per point.
    case standard
    /// Every pixel the display has.
    case native
}

enum ConnectionPreference: String, Codable, CaseIterable {
    case automatic, usbOnly, wifiOnly

    var allowsUSB: Bool { self != .wifiOnly }
    var allowsWiFi: Bool { self != .usbOnly }
}

/// A virtual monitor the app adds to macOS while a session runs.
struct VirtualMonitorSpec: Codable, Equatable, Identifiable {
    /// Also the display's serial number and its video stream identifier.
    var id: UInt32
    var width: Int
    var height: Int
    var hiDPI: Bool

    static let presets: [(name: String, width: Int, height: Int)] = [
        ("1280 × 720", 1280, 720),
        ("1440 × 900", 1440, 900),
        ("1680 × 1050", 1680, 1050),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
    ]
}

/// A scaled resolution to switch the main display to while a session runs.
struct SessionResolution: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
}

struct ViewSettings: Codable, Equatable {
    var mode: ViewMode = .anchored
    var screenAngle = SceneState.defaultScreenAngle
    var distance = 1.5
    var curve: CurvePreference = .automatic
    var showStats = false
    var centerFollowsCursor = false
}

struct SurroundingsSettings: Codable, Equatable {
    var environment = EnvironmentSettings()
    var imagePath: String?
    /// What the passthrough toggle returns to.
    var kindBeforePassthrough: EnvironmentSettings.Kind = .solid
}

struct PrivacySettings: Codable, Equatable {
    var mode: PrivacyMode = .cover
    var coverStyle: CoverStyle = .logo
    var coverImagePath: String?
}

struct DisplaySettings: Codable, Equatable {
    var multiMonitor = false
    var virtualMonitors = [VirtualMonitorSpec(id: 1, width: 1440, height: 900, hiDPI: true)]
    var includeExternalDisplays = false
    var sessionResolution: SessionResolution?
}

struct QualitySettings: Codable, Equatable {
    var codec: VideoCodec = .h264
    var framesPerSecond = 120
    var megabitsPerSecond = 20.0
    var resolution: ResolutionPreference = .automatic
}

/// Recordings and screenshots of the headset view.
struct CaptureSettings: Codable, Equatable {
    /// Folder they are saved in. Nil is a LaptopVR folder in Movies.
    var folderPath: String?
    /// Angle the picture spans from left to right, in degrees.
    var fieldOfView = 110.0

    static let fieldOfViewRange = 60.0...130.0

    var folder: URL {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.moviesDirectory.appending(path: "LaptopVR", directoryHint: .isDirectory)
    }
}

struct GeneralSettings: Codable, Equatable {
    var connection: ConnectionPreference = .automatic
    /// Start when the iPhone enters its headset view and stop when it leaves.
    var startsWithHeadset = true
    var hasCompletedOnboarding = false
}

/// Everything the user can configure. Each group decodes independently, so adding a field to one
/// group in a later version resets only that group to its defaults.
struct AppSettings: Codable, Equatable {
    var view = ViewSettings()
    var surroundings = SurroundingsSettings()
    var privacy = PrivacySettings()
    var displays = DisplaySettings()
    var quality = QualitySettings()
    var capture = CaptureSettings()
    var general = GeneralSettings()
    var shortcuts = Shortcut.defaults

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        view = (try? container.decode(ViewSettings.self, forKey: .view)) ?? ViewSettings()
        surroundings = (try? container.decode(SurroundingsSettings.self, forKey: .surroundings)) ?? SurroundingsSettings()
        privacy = (try? container.decode(PrivacySettings.self, forKey: .privacy)) ?? PrivacySettings()
        displays = (try? container.decode(DisplaySettings.self, forKey: .displays)) ?? DisplaySettings()
        quality = (try? container.decode(QualitySettings.self, forKey: .quality)) ?? QualitySettings()
        capture = (try? container.decode(CaptureSettings.self, forKey: .capture)) ?? CaptureSettings()
        general = (try? container.decode(GeneralSettings.self, forKey: .general)) ?? GeneralSettings()
        let saved = (try? container.decode([HotkeyAction: Shortcut].self, forKey: .shortcuts)) ?? [:]
        // Keep defaults for actions added since the settings were saved.
        shortcuts = Shortcut.defaults.merging(saved) { _, saved in saved }
    }

    private static let storageKey = "settings.v2"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
