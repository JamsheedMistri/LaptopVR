import ServiceManagement
import SwiftUI
import VRProtocol

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("View", systemImage: "eye") { ViewTab(model: model) }
            Tab("Displays", systemImage: "display.2") { DisplaysTab(model: model) }
            Tab("Surroundings", systemImage: "mountain.2") { SurroundingsTab(model: model) }
            Tab("Privacy", systemImage: "eye.slash") { PrivacyTab(model: model) }
            Tab("Quality", systemImage: "dial.medium") { QualityTab(model: model) }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsTab(model: model) }
            Tab("General", systemImage: "gearshape") { GeneralTab(model: model) }
        }
        .frame(width: 580, height: 520)
    }
}

// MARK: - View

private struct ViewTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.settings.view.mode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.settings.view.mode.explanation)
            }

            Section {
                LabeledContent("Screen width") {
                    Slider(value: $model.settings.view.screenAngle, in: SceneState.screenAngleRange)
                    Text("\(Int(model.settings.view.screenAngle.rounded()))°")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                LabeledContent("Distance") {
                    Slider(value: $model.settings.view.distance, in: SceneState.distanceRange)
                    Text(String(format: "%.1f m", model.settings.view.distance))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Picker("Shape", selection: $model.settings.view.curve) {
                    ForEach(CurvePreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Screen width is the zoom: how much of your view the main screen fills. Distance sets how far away the screens appear in 3D. Automatic shape is flat for one screen and curved around you for several.")
            }

            Section {
                Toggle("Center the screen the pointer is on", isOn: $model.settings.view.centerFollowsCursor)
                Toggle("Show statistics in the headset", isOn: $model.settings.view.showStats)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Displays

private struct DisplaysTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Main screen resolution", selection: $model.settings.displays.sessionResolution) {
                    Text("Keep current").tag(SessionResolution?.none)
                    ForEach(SessionResolutionSwitcher.options(for: CGMainDisplayID()), id: \.self) { option in
                        Text(verbatim: "\(option.width) × \(option.height)").tag(Optional(option))
                    }
                }
            } footer: {
                Text("A lower resolution makes text larger and easier to read in the headset. Your Mac switches back when the session ends.")
            }

            Section {
                Toggle("Extra monitors", isOn: $model.settings.displays.multiMonitor)

                ForEach($model.settings.displays.virtualMonitors) { $monitor in
                    HStack {
                        Text("Monitor \(monitor.id)")
                        Spacer()
                        Picker("Size", selection: size(of: $monitor)) {
                            ForEach(VirtualMonitorSpec.presets, id: \.name) { preset in
                                Text(preset.name).tag(SessionResolution(width: preset.width, height: preset.height))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Toggle("Retina", isOn: $monitor.hiDPI)
                            .toggleStyle(.checkbox)
                        Button {
                            model.settings.displays.virtualMonitors.removeAll { $0.id == monitor.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this monitor")
                    }
                }

                Button("Add Monitor") {
                    model.addVirtualMonitor()
                }
                .disabled(
                    model.settings.displays.multiMonitor
                        && model.settings.displays.virtualMonitors.count >= AppModel.maxVirtualMonitors
                )

                Toggle("Also show displays plugged into this Mac", isOn: $model.settings.displays.includeExternalDisplays)
            } footer: {
                Text("Your main screen is always shown. Extra monitors exist only in the headset: macOS treats each one as a real display, so you can drag windows onto it.")
            }

            Section {
                ArrangementEditor(model: model)
                    .frame(height: 150)
            } header: {
                Text("Arrangement")
            } footer: {
                Text("Drag a monitor to place it. Extra monitors appear here while a session is running, and macOS remembers where you put them.")
            }
        }
        .formStyle(.grouped)
    }

    private func size(of monitor: Binding<VirtualMonitorSpec>) -> Binding<SessionResolution> {
        Binding(
            get: { SessionResolution(width: monitor.wrappedValue.width, height: monitor.wrappedValue.height) },
            set: { size in
                var spec = monitor.wrappedValue
                spec.width = size.width
                spec.height = size.height
                monitor.wrappedValue = spec
            }
        )
    }
}

// MARK: - Surroundings

private struct SurroundingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        let kind = model.settings.surroundings.environment.kind

        Form {
            Section {
                Picker("Show", selection: $model.settings.surroundings.environment.kind) {
                    ForEach(EnvironmentSettings.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch kind {
                case .solid:
                    ColorPicker("Color", selection: $model.settings.surroundings.environment.primaryColor.color, supportsOpacity: false)
                case .gradient:
                    ColorPicker("Top", selection: $model.settings.surroundings.environment.primaryColor.color, supportsOpacity: false)
                    ColorPicker("Bottom", selection: $model.settings.surroundings.environment.secondaryColor.color, supportsOpacity: false)
                case .image:
                    LabeledContent("Image") {
                        if let path = model.settings.surroundings.imagePath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Button("Choose…") {
                            if let url = ImageChooser.choose() {
                                model.setSurroundingsImage(from: url)
                            }
                        }
                    }
                case .passthrough:
                    EmptyView()
                }

                if kind == .image || kind == .passthrough {
                    LabeledContent("Dimming") {
                        Slider(value: $model.settings.surroundings.environment.dimming, in: 0...0.9)
                    }
                }
            } footer: {
                switch kind {
                case .solid, .gradient:
                    Text("Darker surroundings make the screens easier on the eyes.")
                case .image:
                    Text("A panorama twice as wide as it is tall wraps all the way around you. Other pictures fill the view ahead.")
                case .passthrough:
                    Text("Shows the room through the iPhone's camera, with the screens on top. The camera uses more battery and warms the iPhone.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("During a session", selection: $model.settings.privacy.mode) {
                    Text("Leave the screen on").tag(PrivacyMode.off)
                    Text("Turn the backlight off").tag(PrivacyMode.backlight)
                    Text("Cover the screen").tag(PrivacyMode.cover)
                    Text("Backlight off and cover").tag(PrivacyMode.both)
                }
                if !Backlight.isAvailable, model.settings.privacy.mode.usesBacklight {
                    Label("This Mac's display brightness cannot be controlled, so only the cover applies.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Keeps your desktop private while you see it in the headset. The cover is left out of what the headset shows, so anyone who turns the brightness back up sees the cover, not your work.")
            }

            if model.settings.privacy.mode.usesCover {
                Section("Cover") {
                    Picker("Show", selection: $model.settings.privacy.coverStyle) {
                        ForEach(CoverStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if model.settings.privacy.coverStyle == .image {
                        LabeledContent("Image") {
                            Button("Choose…") {
                                if let url = ImageChooser.choose() {
                                    model.setCoverImage(from: url)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Show the Mac screen again") {
                    Text(model.settings.shortcuts[.revealScreen]?.label ?? "")
                        .font(.body.monospaced())
                }
            } footer: {
                Text("Press this at any time during a session to bring the Mac's own screen back without stopping. Stopping the session always restores it.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quality

private struct QualityTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $model.settings.quality.resolution) {
                    ForEach(ResolutionPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Frame rate", selection: $model.settings.quality.framesPerSecond) {
                    ForEach([60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                LabeledContent("Bitrate per screen") {
                    Slider(value: $model.settings.quality.megabitsPerSecond, in: 4...80)
                    Text("\(Int(model.settings.quality.megabitsPerSecond.rounded())) Mbps")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            } footer: {
                Text("Automatic resolution sends as many pixels as the viewer can resolve at the current zoom. Frames are sent only when the screen changes, so a higher frame rate costs little while you read or type.")
            }

            Section {
                Picker("Codec", selection: $model.settings.quality.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("H.264 usually decodes fastest. HEVC looks sharper at the same bitrate, which helps on Wi-Fi. Turn on statistics in the headset to compare them on your devices.")
            }

            if let summary = model.statsSummary {
                Section("Now") {
                    LabeledContent("Main screen", value: summary)
                    ForEach(model.stats, id: \.stream) { stream in
                        LabeledContent("Stream \(stream.stream)") {
                            Text(verbatim: "\(stream.width) × \(stream.height) · encode \(String(format: "%.1f", stream.encodeMillis)) ms · \(stream.droppedFrames) dropped")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(shortcut: binding(for: action), hotkeys: model.hotkeys)
                    }
                }
            } footer: {
                Text("Shortcuts work in any app. Only the start shortcut is active while no session is running. Click one to change it; press Delete to clear it.")
            }

            Section {
                Button("Restore Defaults") {
                    model.settings.shortcuts = Shortcut.defaults
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: HotkeyAction) -> Binding<Shortcut> {
        Binding(
            get: { model.settings.shortcuts[action] ?? .unassigned },
            set: { model.settings.shortcuts[action] = $0 }
        )
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $model.settings.general.connection) {
                    ForEach(ConnectionPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Start when the iPhone enters the headset view", isOn: $model.settings.general.startsWithHeadset)
            } footer: {
                Text("Automatic uses the cable whenever one is plugged in and Wi-Fi otherwise. A cable has the lowest and steadiest delay, and keeps the iPhone charged.")
            }

            Section {
                LabeledContent("Save to") {
                    Text((model.settings.capture.folder.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        if let url = FolderChooser.choose() {
                            model.settings.capture.folderPath = url.path
                        }
                    }
                }
                LabeledContent("Field of view") {
                    Slider(value: $model.settings.capture.fieldOfView, in: CaptureSettings.fieldOfViewRange)
                    Text("\(Int(model.settings.capture.fieldOfView.rounded()))°")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            } header: {
                Text("Recordings and Screenshots")
            } footer: {
                Text("Recordings and screenshots show the headset view as one flat picture. A wider field of view takes in more of the screens at once and stretches them toward its edges.")
            }

            Section {
                Toggle("Open at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in
                        do {
                            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch {
                            launchesAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Screen Recording") {
                    if model.hasScreenRecordingPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") { model.requestScreenRecordingPermission() }
                    }
                }
                Button("Show Welcome") {
                    (NSApp.delegate as? AppDelegate)?.showWelcome()
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermission() }
    }
}
