import CoreVideo
import Foundation
import Metal
import simd
import VRProtocol

extension RendererError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .metalUnavailable: "This Mac cannot draw the headset view."
        case .shader(let message): "The headset view could not be prepared: \(message)"
        }
    }
}

/// Draws what the wearer sees as one flat picture: the same scene the iPhone draws, seen from
/// between the eyes through an ordinary camera instead of a viewer's lenses.
///
/// The Mac has nearly everything this needs. It lays out the scene itself, it holds every
/// screen's picture before it is encoded, and the phone reports where the head is pointing. Only
/// the camera's picture, for passthrough, has to come from the phone. Not safe to use from more
/// than one thread at a time.
final class ViewRenderer {
    /// One moment of the view.
    struct View {
        var scene: SceneState
        var pose: ViewPose
        /// The newest picture of each screen, by stream.
        var frames: [UInt16: CVPixelBuffer]
        /// The newest picture from the phone's camera, if the scene looks through it and one
        /// has arrived. Without one, passthrough is black, as it is in the headset.
        var camera: CameraFeed.Frame?
        /// Angle the picture spans from left to right.
        var fieldOfViewDegrees: Double

        /// True if the scene looks through the camera and there is no picture from it.
        var lacksCamera: Bool { scene.environment.kind == .passthrough && camera == nil }
    }

    private let resources: SceneResources
    private let pipeline: any MTLRenderPipelineState
    private var screenImages: [UInt16: VideoImage] = [:]
    private var cameraImage: VideoImage?
    private var surroundingsImage: SurroundingsImage?

    init() throws {
        resources = try SceneResources()
        pipeline = try resources.makePipeline(fragment: "flatFragment")
    }

    /// Describes a pixel buffer of the kind `draw` fills.
    static func targetAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
    }

    /// Draws the view into `target` and returns once the picture is there. `surroundings` is
    /// the picture the scene's surroundings may refer to.
    func draw(_ view: View, surroundings: AssetMessage?, into target: CVPixelBuffer) -> Bool {
        let scene = view.scene
        let screens = Array(scene.screens.prefix(LaptopVRProtocol.maxScreens))

        guard let wrapped = resources.makeTarget(target),
              let texture = CVMetalTextureGetTexture(wrapped),
              let commandBuffer = resources.commandQueue.makeCommandBuffer()
        else { return false }

        var uniforms = SceneUniforms()
        uniforms.sceneFromEye = simd_float4x4(rotation: Self.rotation(view.pose.sceneFromEye))
        uniforms.surroundingsFromEye = simd_float4x4(rotation: Self.rotation(view.pose.surroundingsFromEye))
        uniforms.headPosition = SIMD4(view.pose.headPosition, 0)
        uniforms.viewport = SIMD4(Float(texture.width), Float(texture.height), 0, 0)
        uniforms.optics = SIMD4(tan(Float(view.fieldOfViewDegrees) * .pi / 360), 0, 0, 0)
        uniforms.setLayout(scene, screenCount: screens.count, focus: view.pose.focus)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)

        let held = HeldImages()
        _ = resources.bindScreens(
            screens, frames: view.frames, images: &screenImages, to: encoder, uniforms: &uniforms, held: held)
        resources.bindSurroundings(
            scene.environment, image: surroundingsImage(for: scene.environment, from: surroundings),
            to: encoder, uniforms: &uniforms)
        if scene.environment.kind == .passthrough, let camera = view.camera {
            // Both rotations are measured against the surroundings, which only recentering moves.
            resources.bindCamera(
                camera.pixelBuffer, intrinsics: camera.intrinsics,
                cameraFromEye: Self.rotation(camera.surroundingsFromCamera).transpose
                    * Self.rotation(view.pose.surroundingsFromEye),
                image: &cameraImage, to: encoder, uniforms: &uniforms, held: held)
        } else {
            cameraImage = nil
        }

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return withExtendedLifetime((held, wrapped)) { commandBuffer.status == .completed }
    }

    /// Lets go of the screens' and the camera's pictures. They come from small pools that
    /// capture and decoding need back, so call this when no more drawing is expected for a while.
    func releaseFrames() {
        screenImages = [:]
        cameraImage = nil
    }

    /// The surroundings picture as a texture, decoded the first time a scene asks for it.
    private func surroundingsImage(for environment: EnvironmentSettings, from asset: AssetMessage?) -> SurroundingsImage? {
        guard environment.kind == .image, let asset, asset.id == environment.imageAssetID else { return nil }
        if surroundingsImage?.id != asset.id {
            surroundingsImage = resources.makeSurroundingsImage(id: asset.id, data: asset.data)
        }
        return surroundingsImage
    }

    /// A quaternion from the phone as a rotation, or no rotation if it is not a usable one.
    private static func rotation(_ vector: SIMD4<Float>) -> simd_float3x3 {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.5 else { return matrix_identity_float3x3 }
        return simd_float3x3(simd_quatf(vector: vector / length))
    }
}
