import SwiftUI

/// The portrait screen: connection state, the way into the headset view, and viewer setup.
struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    brand
                    connectionCard
                    enterButton
                    optionsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.accentColor.opacity(0.14)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $model.isInHeadset) {
            HeadsetScreen(model: model)
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 84)
            // The name is set the way the brand writes it: a light "Laptop" and a heavy "VR".
            Text("Laptop\(Text("VR").fontWeight(.bold))")
                .font(.title2)
        }
        .foregroundStyle(.primary)
        .padding(.top, 12)
        .accessibilityElement()
        .accessibilityLabel("LaptopVR")
    }

    private var connectionCard: some View {
        HStack(spacing: 14) {
            Group {
                switch model.link {
                case .searching:
                    ProgressView()
                case .connected(_, let transport):
                    Image(systemName: transport == "USB" ? "cable.connector" : "wifi")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                switch model.link {
                case .searching:
                    Text("Looking for your Mac")
                        .font(.headline)
                    Text(model.listenerError ?? "Open LaptopVR on your Mac, then plug in this iPhone or join the same Wi-Fi network.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .connected(let host, let transport):
                    Text(host)
                        .font(.headline)
                    Text(model.scene.sessionActive ? "Streaming over \(transport)" : "Connected over \(transport)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 22))
        .animation(.default, value: model.link)
    }

    private var enterButton: some View {
        VStack(spacing: 10) {
            Button {
                model.isInHeadset = true
            } label: {
                Label("Enter Headset", systemImage: "eyeglasses")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.rendererError != nil)

            Text(model.rendererError ?? "Then turn your iPhone sideways and place it in the viewer. Tap the screen at any time to recenter.")
                .font(.footnote)
                .foregroundStyle(model.rendererError == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
        }
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ViewerSetupView(model: model)
            } label: {
                HStack {
                    Label("Viewer", systemImage: "qrcode.viewfinder")
                    Spacer()
                    Text(model.profile.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(18)

            Divider()
                .padding(.leading, 18)

            Toggle(isOn: $model.entersAutomatically) {
                Label("Enter when the Mac starts", systemImage: "play.circle")
            }
            .padding(18)
        }
        .glassEffect(in: .rect(cornerRadius: 22))
    }
}
