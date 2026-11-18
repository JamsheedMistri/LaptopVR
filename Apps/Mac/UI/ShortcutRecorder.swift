import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that shows a shortcut and, when clicked, records the next key combination.
/// Escape cancels and Delete clears the shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let hotkeys: HotkeyCenter

    @State private var monitor: Any?

    private var isRecording: Bool { monitor != nil }

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Type shortcut…" : (shortcut.isAssigned ? shortcut.label : "None"))
                .font(.body.monospaced())
                .foregroundStyle(isRecording || !shortcut.isAssigned ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        // Combinations that are registered globally never reach the app as key presses.
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
                stop()
            } else if modifiers.isEmpty, Int(event.keyCode) == kVK_Delete {
                shortcut = .unassigned
                stop()
            } else if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        hotkeys.resume()
    }
}
