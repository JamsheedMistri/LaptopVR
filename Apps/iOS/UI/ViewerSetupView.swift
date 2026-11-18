import SwiftUI

/// Chooses the viewer the iPhone sits in, so the picture matches its lenses.
struct ViewerSetupView: View {
    @Bindable var model: AppModel
    @State private var isScanning = false
    @State private var scanFailed = false

    var body: some View {
        Form {
            Section {
                Button {
                    isScanning = true
                } label: {
                    Label("Scan Viewer QR Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Most viewers have a QR code printed on them that describes their lenses. It is the same code the Google Cardboard app asks for.")
            }

            Section("Viewer") {
                ForEach(ViewerProfile.presets, id: \.name) { preset in
                    Button {
                        model.profile = preset
                    } label: {
                        HStack {
                            Text(preset.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.profile == preset {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
                if !ViewerProfile.presets.contains(model.profile) {
                    HStack {
                        Text(model.profile.name)
                        Spacer()
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
            }

            Section {
                Adjustment(
                    title: "Lens spacing", value: $model.profile.lensSeparation, range: 0.050...0.075,
                    format: { String(format: "%.0f mm", $0 * 1000) })
                Adjustment(
                    title: "Lens distance", value: $model.profile.screenToLens, range: 0.025...0.060,
                    format: { String(format: "%.0f mm", $0 * 1000) })
                Adjustment(
                    title: "Distortion", value: $model.profile.k1, range: 0...0.8,
                    format: { String(format: "%.2f", $0) })
                Adjustment(
                    title: "Edge distortion", value: $model.profile.k2, range: 0...0.8,
                    format: { String(format: "%.2f", $0) })
            } header: {
                Text("Fine tuning")
            } footer: {
                Text("If you see double, change the lens spacing. If straight lines bow near the edges, change the distortion. If the picture swims when you turn your head, change the lens distance.")
            }
        }
        .navigationTitle("Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isScanning) {
            ScannerSheet { text in
                isScanning = false
                Task {
                    if let profile = await CardboardCode.profile(from: text) {
                        model.profile = profile
                    } else {
                        scanFailed = true
                    }
                }
            }
        }
        .alert("That is not a viewer code", isPresented: $scanFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a viewer from the list instead, then adjust it under Fine tuning.")
        }
    }
}

private struct Adjustment: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: (Float) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScanner(onCode: onCode)
                .ignoresSafeArea()
                .navigationTitle("Scan Viewer Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}
