import SwiftUI

/// Shown on first launch: the one permission the app needs, how to connect, and how to get the
/// Mac's screen back.
struct WelcomeView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
                Text("Welcome to LaptopVR")
                    .font(.largeTitle.weight(.semibold))
                Text("Your Mac's screen, in a headset made from your iPhone.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Step(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Allow Screen Recording",
                    detail: "LaptopVR captures your screen to show it in the headset. Nothing leaves your Mac except to your iPhone. If you just allowed it, quit and reopen LaptopVR.",
                    isDone: model.hasScreenRecordingPermission
                ) {
                    Button("Allow…") { model.requestScreenRecordingPermission() }
                }

                Step(
                    symbol: "iphone",
                    title: "Open LaptopVR on your iPhone",
                    detail: model.peer.map { "Connected to \($0.name) over \($0.transport.title)." }
                        ?? "Plug the iPhone in for the lowest delay, or join the same Wi-Fi network.",
                    isDone: model.peer != nil
                )

                Step(
                    symbol: "eye.slash",
                    title: "Your Mac's screen goes dark",
                    detail: "While you are in the headset, the Mac's own screen is hidden. Press \(label(.revealScreen)) to bring it back, or \(label(.toggleSession)) to stop.",
                    isDone: nil
                )

                Step(
                    symbol: "menubar.arrow.up.rectangle",
                    title: "Find the controls in the menu bar",
                    detail: "Zoom, recenter, surroundings, and extra monitors are one click away, and each has a keyboard shortcut.",
                    isDone: nil
                )
            }

            Button("Get Started") {
                model.settings.general.hasCompletedOnboarding = true
                close()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 520)
        .task {
            // The permission is granted in System Settings, outside the app.
            while !Task.isCancelled {
                model.refreshPermission()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func label(_ action: HotkeyAction) -> String {
        model.settings.shortcuts[action]?.label ?? ""
    }
}

private struct Step<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    /// Nil for steps that are information rather than something to complete.
    let isDone: Bool?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isDone == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else if isDone == false {
                accessory
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}

extension Step where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String, isDone: Bool?) {
        self.init(symbol: symbol, title: title, detail: detail, isDone: isDone) { EmptyView() }
    }
}
