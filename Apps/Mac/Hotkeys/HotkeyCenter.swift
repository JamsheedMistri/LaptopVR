import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts with Carbon's `RegisterEventHotKey`, which works
/// without Accessibility or Input Monitoring permission because the system only tells the app
/// about the exact combinations it registered.
@MainActor
final class HotkeyCenter {
    var onAction: ((HotkeyAction) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var shortcuts: [HotkeyAction: Shortcut] = [:]

    private static let signature: OSType = 0x4C56_5248 // "LVRH"

    /// Replaces all registered shortcuts.
    func register(_ shortcuts: [HotkeyAction: Shortcut]) {
        self.shortcuts = shortcuts
        unregisterAll()
        installHandlerIfNeeded()

        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action], shortcut.isAssigned else { continue }
            let identifier = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: identifier),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            // Registration fails if another app already owns the combination.
            if status == noErr, let reference {
                registrations.append(reference)
                actions[identifier] = action
            }
        }
    }

    /// Temporarily releases every shortcut, so the shortcut recorder can capture key presses
    /// that are currently bound.
    func suspend() {
        unregisterAll()
    }

    func resume() {
        register(shortcuts)
    }

    private func unregisterAll() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations = []
        actions = [:]
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var hotKey = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKey
                )
                guard status == noErr, let userData else { return status }
                let identifier = hotKey.id
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    center.fire(identifier)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func fire(_ identifier: UInt32) {
        guard let action = actions[identifier] else { return }
        onAction?(action)
    }
}
