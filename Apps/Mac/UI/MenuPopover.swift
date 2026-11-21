import SwiftUI
import VRProtocol

/// The window that drops down from the menu bar icon: everything needed during a session.
struct MenuPopover: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.lastError {
                Notice(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let error = model.captureError {
                Notice(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if !model.hasScreenRecordingPermission {
                Notice(
                    text: "Allow Screen Recording so LaptopVR can show your screen in the headset.",
                    symbol: "lock.fill",
                    tint: .yellow,
                    actionTitle: "Allow…"
                ) {
                    model.requestScreenRecordingPermission()
                }
            }

            Divider()
            viewControls
            surroundings
            monitors

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshPermission() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("LaptopVR")
                    .font(.headline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(model.isActive ? "Stop" : "Start") {
                model.toggleSession()
            }
            .buttonStyle(.glassProminent)
            .tint(model.isActive ? .red : .accentColor)
            .disabled(model.peer == nil && !model.isActive)
            .help(shortcutHelp(.toggleSession))
        }
    }

    private var viewControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $model.settings.view.mode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(model.settings.view.mode.explanation)

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $model.zoomAngle, in: SceneState.screenAngleRange)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .help("How much of your view the main screen fills")

            HStack(spacing: 8) {
                ActionButton(title: "Recenter", symbol: "scope", help: shortcutHelp(.recenter)) {
                    model.recenter()
                }
                ActionButton(title: "Cinema", symbol: "film", isOn: model.isCinema, help: shortcutHelp(.cinema)) {
                    model.toggleCinema()
                }
                ActionButton(
                    title: model.isScreenRevealed ? "Hide Mac" : "Show Mac",
                    symbol: model.isScreenRevealed ? "eye.slash" : "eye",
                    isOn: model.isScreenRevealed,
                    help: shortcutHelp(.revealScreen)
                ) {
                    model.toggleReveal()
                }
            }
            .disabled(model.phase != .running)

            HStack(spacing: 8) {
                ActionButton(
                    title: "Record",
                    symbol: model.isRecording ? "stop.circle.fill" : "record.circle",
                    isOn: model.isRecording,
                    tint: .red,
                    since: model.recordingStartedAt,
                    help: shortcutHelp(.toggleRecording)
                ) {
                    model.toggleRecording()
                }
                ActionButton(title: "Screenshot", symbol: "camera.viewfinder", help: shortcutHelp(.screenshot)) {
                    model.takeScreenshot()
                }
            }
            .disabled(model.phase != .running)

            if let capture = model.lastCapture {
                HStack(spacing: 6) {
                    Text(capture.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([capture])
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }

    private var surroundings: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Surroundings")
            // A segmented control with these four names is wider than the popover.
            HStack(spacing: 6) {
                ForEach(EnvironmentSettings.Kind.allCases, id: \.self) { kind in
                    ChoiceTile(
                        title: kind.title,
                        symbol: kind.symbol,
                        isOn: kind == model.settings.surroundings.environment.kind
                    ) {
                        model.settings.surroundings.environment.kind = kind
                    }
                }
            }

            if model.settings.surroundings.environment.kind == .image, model.settings.surroundings.imagePath == nil {
                Button("Choose Image…") {
                    if let url = ImageChooser.choose() {
                        model.setSurroundingsImage(from: url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var monitors: some View {
        VStack(alignment: .leading, spacing: 8) {
            monitorCount

            // One button per screen in the headset; clicking brings that screen to the centre.
            if model.phase == .running, model.shownDisplays.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.shownDisplays.sorted { $0.bounds.minX < $1.bounds.minX }) { display in
                            Button(display.name) {
                                model.focus(stream: display.streamID)
                            }
                            .buttonStyle(.glass)
                            .tint(display.streamID == model.focusedStream ? .accentColor : nil)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Bring a screen to the center")
            }
        }
    }

    private var monitorCount: some View {
        HStack {
            Toggle("Extra monitors", isOn: $model.settings.displays.multiMonitor)
                .toggleStyle(.switch)
                .controlSize(.small)

            Spacer()

            if model.settings.displays.multiMonitor {
                let count = model.settings.displays.virtualMonitors.count
                HStack(spacing: 6) {
                    Button {
                        model.removeVirtualMonitor()
                    } label: {
                        Image(systemName: "minus")
                    }
                    Text("\(count)")
                        .monospacedDigit()
                        .frame(minWidth: 14)
                    Button {
                        model.addVirtualMonitor()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(count >= AppModel.maxVirtualMonitors)
                }
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let status = model.phoneStatus {
                    PhoneStatusLine(status: status)
                }
                if let summary = model.statsSummary {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit LaptopVR")
        }
        .buttonStyle(.borderless)
    }

    private func shortcutHelp(_ action: HotkeyAction) -> String {
        guard let shortcut = model.settings.shortcuts[action], shortcut.isAssigned else { return action.title }
        return "\(action.title) (\(shortcut.label))"
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var isOn = false
    var tint = Color.accentColor
    /// When set, the time since then is shown counting up in place of the title.
    var since: Date?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                if let since {
                    Text(since, style: .timer)
                        .monospacedDigit()
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: symbol)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(isOn ? tint : nil)
        .help(help)
    }
}

/// One of a row of equally wide choices, each an icon over its name.
private struct ChoiceTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.body)
                    .frame(height: 16)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .rect(cornerRadius: 10))
        }
        // A bordered style would add side padding the narrow tiles cannot afford.
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct Notice: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PhoneStatusLine: View {
    let status: ClientStatus

    var body: some View {
        HStack(spacing: 6) {
            if let level = status.batteryLevel {
                Label("\(Int((level * 100).rounded()))%", systemImage: batterySymbol(level))
            }
            if status.thermalState >= 2 {
                Label("iPhone is hot", systemImage: "thermometer.high")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func batterySymbol(_ level: Double) -> String {
        if status.isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<0.2: return "battery.25percent"
        case ..<0.6: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
