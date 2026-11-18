import SwiftUI
import UIKit

/// The landscape stereo view that goes in the viewer. A tap anywhere recenters, which is also
/// what a Cardboard viewer's button does, since it touches the screen.
struct HeadsetScreen: View {
    let model: AppModel

    var body: some View {
        // The button sits between the eyes, where the viewer's divider hides it.
        ZStack(alignment: .top) {
            HeadsetSurface(model: model)
                .ignoresSafeArea()

            Button {
                model.isInHeadset = false
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: .circle)
            }
            .padding(12)
            .accessibilityLabel("Leave headset view")
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

private struct HeadsetSurface: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> HeadsetViewController {
        HeadsetViewController(model: model)
    }

    func updateUIViewController(_ controller: HeadsetViewController, context: Context) {}
}

/// Hosts the Metal layer the renderer draws into, and tells the renderer about the glass: how
/// big its pixels are and which way round the phone is.
final class HeadsetViewController: UIViewController {
    private final class MetalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
    }

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        view = MetalView()
        view.backgroundColor = .black
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(recenter)))
    }

    @objc private func recenter() {
        model.recenter()
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // A stray touch at the edge while seating the phone should not leave the app.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let layer = view.layer as? CAMetalLayer {
            model.renderer?.start(layer: layer)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.renderer?.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let layer = view.layer as? CAMetalLayer, let windowScene = view.window?.windowScene else { return }

        // Draw at the panel's own resolution, one drawn pixel per physical pixel.
        let screen = windowScene.screen
        layer.contentsScale = screen.nativeScale
        layer.drawableSize = CGSize(
            width: view.bounds.width * screen.nativeScale,
            height: view.bounds.height * screen.nativeScale
        )

        model.renderer?.setDisplay(
            side: windowScene.effectiveGeometry.interfaceOrientation == .landscapeLeft ? .left : .right,
            pixelsPerMeter: DisplayMetrics.pixelsPerMeter(of: screen)
        )
    }
}
