import AppKit
import Carbon.HIToolbox

/// Things a global keyboard shortcut can trigger.
enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case toggleSession
    case recenter
    case zoomIn
    case zoomOut
    case toggleMode
    case togglePassthrough
    case revealScreen
    case cinema
    case nextDisplay
    case previousDisplay
    case addMonitor
    case removeMonitor
    case toggleStats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleSession: "Start or stop LaptopVR"
        case .recenter: "Recenter"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .toggleMode: "Switch between Anchored and Follow"
        case .togglePassthrough: "Toggle passthrough"
        case .revealScreen: "Reveal or hide the Mac screen"
        case .cinema: "Toggle cinema view"
        case .nextDisplay: "Center next display"
        case .previousDisplay: "Center previous display"
        case .addMonitor: "Add a virtual monitor"
        case .removeMonitor: "Remove a virtual monitor"
        case .toggleStats: "Toggle statistics overlay"
        }
    }
}

/// A key combination, stored with Carbon key codes and modifier flags because that is what
/// `RegisterEventHotKey` takes.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Text shown in the UI, for example "⌃⌥⌘R".
    var label: String

    static let unassigned = Shortcut(keyCode: .max, modifiers: 0, label: "")

    var isAssigned: Bool { keyCode != .max }

    private static let chord = UInt32(controlKey | optionKey | cmdKey)

    private static func standard(_ keyCode: Int, _ key: String) -> Shortcut {
        Shortcut(keyCode: UInt32(keyCode), modifiers: chord, label: "⌃⌥⌘" + key)
    }

    static let defaults: [HotkeyAction: Shortcut] = [
        .toggleSession: standard(kVK_ANSI_V, "V"),
        .recenter: standard(kVK_Space, "Space"),
        .zoomIn: standard(kVK_ANSI_Equal, "="),
        .zoomOut: standard(kVK_ANSI_Minus, "-"),
        .toggleMode: standard(kVK_ANSI_M, "M"),
        .togglePassthrough: standard(kVK_ANSI_P, "P"),
        .revealScreen: standard(kVK_ANSI_R, "R"),
        .cinema: standard(kVK_ANSI_C, "C"),
        .nextDisplay: standard(kVK_RightArrow, "→"),
        .previousDisplay: standard(kVK_LeftArrow, "←"),
        .addMonitor: standard(kVK_ANSI_N, "N"),
        .removeMonitor: standard(kVK_Delete, "⌫"),
        .toggleStats: standard(kVK_ANSI_S, "S"),
    ]

    /// Builds a shortcut from a key press, or nil if it has no Command, Control, or Option
    /// modifier (a bare key would hijack normal typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        guard modifiers & Self.chord != 0 else { return nil }

        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + Self.keyName(for: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let name = specialKeyNames[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}
