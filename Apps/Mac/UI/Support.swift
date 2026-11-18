import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VRProtocol

// MARK: - Names shown in the UI

extension ViewMode {
    var title: String {
        switch self {
        case .anchored: "Anchored"
        case .follow: "Follow"
        }
    }

    var explanation: String {
        switch self {
        case .anchored: "Screens stay fixed in space, like real monitors. Turn your head to look around them."
        case .follow: "Screens come along when you look past their edge, so they never leave your view."
        }
    }
}

extension EnvironmentSettings.Kind {
    var title: String {
        switch self {
        case .solid: "Color"
        case .gradient: "Gradient"
        case .image: "Image"
        case .passthrough: "Passthrough"
        }
    }

    var symbol: String {
        switch self {
        case .solid: "paintpalette"
        case .gradient: "circle.lefthalf.filled"
        case .image: "photo"
        case .passthrough: "camera"
        }
    }
}

extension CurvePreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .flat: "Flat"
        case .curved: "Curved"
        }
    }
}

extension CoverStyle {
    var title: String {
        switch self {
        case .black: "Black"
        case .logo: "Logo and hint"
        case .image: "Image"
        }
    }
}

extension ResolutionPreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .standard: "Standard"
        case .native: "Native"
        }
    }
}

extension ConnectionPreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .usbOnly: "USB only"
        case .wifiOnly: "Wi-Fi only"
        }
    }
}

// MARK: - Model summaries

extension AppModel {
    var statusText: String {
        switch phase {
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .running:
            if let peer { "Streaming to \(peer.name) over \(peer.transport.title)" } else { "Reconnecting…" }
        case .idle:
            if let peer { "\(peer.name) connected over \(peer.transport.title)" } else { "Looking for your iPhone…" }
        }
    }

    /// Frame rate and latency of the main screen, and the bitrate of all screens together.
    var statsSummary: String? {
        guard let main = stats.first(where: { $0.stream == 0 }) ?? stats.first else { return nil }
        let megabits = stats.reduce(0) { $0 + $1.megabitsPerSecond }
        return String(
            format: "%.0f fps · %.1f Mbps · %.0f ms",
            main.framesPerSecond, megabits, main.pipelineMillis
        )
    }
}

// MARK: - Colours

// Spelled with the module name because AppKit also brings in QuickDraw's `RGBColor`.
extension VRProtocol.RGBColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    init(_ color: Color) {
        let components = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(components.redComponent),
            green: Double(components.greenComponent),
            blue: Double(components.blueComponent)
        )
    }
}

extension Binding where Value == VRProtocol.RGBColor {
    var color: Binding<Color> {
        Binding<Color>(
            get: { wrappedValue.color },
            set: { wrappedValue = VRProtocol.RGBColor($0) }
        )
    }
}

// MARK: - Choosing a picture

@MainActor
enum ImageChooser {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
