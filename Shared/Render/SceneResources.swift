import CoreVideo
import Foundation
import Metal
import MetalKit
import simd
import VRProtocol

enum RendererError: Error {
    case metalUnavailable
    case shader(String)
}

/// Mirrors `Uniforms` in SceneShader.msl. Only 16-byte-aligned members, so the two layouts
/// agree without padding rules coming into it.
struct SceneUniforms {
    var sceneFromEye = matrix_identity_float4x4
    var surroundingsFromEye = matrix_identity_float4x4
    var cameraFromEye = matrix_identity_float4x4
    var headPosition = SIMD4<Float>()
    var viewport = SIMD4<Float>()
    var lens = SIMD4<Float>()
    var optics = SIMD4<Float>()
    var layout = SIMD4<Float>()
    var focus = SIMD4<Float>()
    var surroundings = SIMD4<Float>()
    var primaryColor = SIMD4<Float>()
    var secondaryColor = SIMD4<Float>()
    var camera = SIMD4<Float>()
    var cameraFormat = SIMD4<Float>()
    var hud = SIMD4<Float>()
    var screenRect = InlineArray<6, SIMD4<Float>>(repeating: SIMD4())
    var screenImage = InlineArray<6, SIMD4<Float>>(repeating: SIMD4())

    /// Where the screens are: how far, how wide, how curved, and which point is straight ahead.
    mutating func setLayout(_ scene: SceneState, screenCount: Int, focus: SIMD2<Float>) {
        let angle = Float(scene.screenAngleDegrees) * .pi / 180
        let distance = Float(scene.distanceMeters)
        layout = SIMD4(distance, distance * angle, Float(scene.curvature), Float(screenCount))
        self.focus = SIMD4(focus.x, focus.y, 0.012, 0)
    }
}

/// Texture slots, matching the shader's arguments.
enum SceneTextureSlot {
    static let screenLuma = 0
    static let screenChroma = 6
    static let cameraLuma = 12
    static let cameraChroma = 13
    static let surroundings = 14
    static let hud = 15
}

/// A video frame's two planes as Metal textures.
struct VideoImage {
    let pixelBuffer: CVPixelBuffer
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
}

/// Keeps textures alive until the GPU has finished the frame that uses them.
final class HeldImages: @unchecked Sendable {
    var images: [VideoImage] = []
}

/// A picture for the surroundings. `id` is what the scene refers to it by.
struct SurroundingsImage {
    let id: String
    let texture: any MTLTexture
}

/// What drawing the scene needs whichever camera it is seen through: the Metal objects, and
/// the steps that hand the screens and the surroundings to the shader.
final class SceneResources: @unchecked Sendable {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    let sampler: any MTLSamplerState
    /// Stands in wherever the shader expects a texture and there is none.
    let blankTexture: any MTLTexture

    private let library: any MTLLibrary
    private let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let blankTexture = device.makeTexture(descriptor: .texture2DDescriptor(
                  pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))
        else { throw RendererError.metalUnavailable }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RendererError.metalUnavailable }

        // The shader ships as source and is compiled here, so building the app does not need
        // Xcode's separate Metal toolchain.
        guard let url = Bundle.main.url(forResource: "SceneShader", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw RendererError.shader("SceneShader.msl is missing from the app.") }
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw RendererError.shader(error.localizedDescription)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.metalUnavailable
        }

        self.device = device
        self.commandQueue = commandQueue
        self.blankTexture = blankTexture
        self.sampler = sampler
        textureCache = cache
    }

    /// A pipeline that draws the scene with one of the shader's cameras into a BGRA picture.
    func makePipeline(fragment: String) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.shader(error.localizedDescription)
        }
    }

    /// Wraps the two planes of a video frame as textures, without copying.
    func makeImage(_ pixelBuffer: CVPixelBuffer) -> VideoImage? {
        func plane(_ index: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, format,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, index), CVPixelBufferGetHeightOfPlane(pixelBuffer, index),
                index, &texture)
            return texture
        }
        guard let luma = plane(0, .r8Unorm), let chroma = plane(1, .rg8Unorm) else { return nil }
        return VideoImage(pixelBuffer: pixelBuffer, luma: luma, chroma: chroma)
    }

    /// Wraps a BGRA pixel buffer as a texture that can be drawn into.
    func makeTarget(_ pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture)
        return texture
    }

    /// Decodes a picture for the surroundings.
    func makeSurroundingsImage(id: String, data: Data) -> SurroundingsImage? {
        let loader = MTKTextureLoader(device: device)
        // Left as encoded, like the video: colours pass through to the picture untouched.
        guard let texture = try? loader.newTexture(data: data, options: [.SRGB: false]) else { return nil }
        return SurroundingsImage(id: id, texture: texture)
    }

    /// Hands each screen's place and newest frame to the shader. `images` carries the textures
    /// from one call to the next, so a frame that is drawn again is wrapped only once. Returns
    /// the streams whose frame had not been drawn before.
    func bindScreens(
        _ screens: [ScreenDescriptor], frames: [UInt16: CVPixelBuffer], images: inout [UInt16: VideoImage],
        to encoder: any MTLRenderCommandEncoder, uniforms: inout SceneUniforms, held: HeldImages
    ) -> Set<UInt16> {
        var current: [UInt16: VideoImage] = [:]
        var fresh: Set<UInt16> = []

        for index in 0..<LaptopVRProtocol.maxScreens {
            var luma = blankTexture
            var chroma = blankTexture

            if index < screens.count {
                let screen = screens[index]
                uniforms.screenRect[index] = SIMD4(
                    Float(screen.centerX), Float(screen.centerY), Float(screen.width), Float(screen.height))

                if let pixelBuffer = frames[screen.id] {
                    var image = images[screen.id]
                    if image?.pixelBuffer !== pixelBuffer {
                        image = makeImage(pixelBuffer)
                        fresh.insert(screen.id)
                    }
                    if let image,
                       let lumaTexture = CVMetalTextureGetTexture(image.luma),
                       let chromaTexture = CVMetalTextureGetTexture(image.chroma) {
                        luma = lumaTexture
                        chroma = chromaTexture
                        current[screen.id] = image
                        held.images.append(image)
                        uniforms.screenImage[index] = SIMD4(1, Float(lumaTexture.width), Float(lumaTexture.height), 0)
                    }
                }
            }
            encoder.setFragmentTexture(luma, index: SceneTextureSlot.screenLuma + index)
            encoder.setFragmentTexture(chroma, index: SceneTextureSlot.screenChroma + index)
        }
        images = current
        return fresh
    }

    /// Hands the surroundings to the shader. For passthrough this leaves the camera's picture
    /// blank; `bindCamera` puts it there afterwards.
    func bindSurroundings(
        _ environment: EnvironmentSettings, image: SurroundingsImage?,
        to encoder: any MTLRenderCommandEncoder, uniforms: inout SceneUniforms
    ) {
        // Spelled with the module name because AppKit also brings in QuickDraw's `RGBColor`.
        func color(_ color: VRProtocol.RGBColor) -> SIMD4<Float> {
            SIMD4(Float(color.red), Float(color.green), Float(color.blue), 1)
        }
        uniforms.primaryColor = color(environment.primaryColor)
        uniforms.secondaryColor = color(environment.secondaryColor)
        let brightness = Float(1 - min(max(environment.dimming, 0), 1))

        var imageTexture = blankTexture
        switch environment.kind {
        case .solid:
            uniforms.surroundings = SIMD4(0, 1, 0, 0)
        case .gradient:
            uniforms.surroundings = SIMD4(1, 1, 0, 0)
        case .image:
            if let image, image.id == environment.imageAssetID {
                imageTexture = image.texture
                let aspect = Float(image.texture.width) / Float(image.texture.height)
                // A 2:1 picture is taken to be a full panorama; anything else fills the view ahead.
                var across: Float = aspect >= 1.9 ? 2 * .pi : 2.6
                var upward = aspect >= 1.9 ? Float.pi : across / aspect
                if upward > 2.4 {
                    upward = 2.4
                    across = upward * aspect
                }
                uniforms.surroundings = SIMD4(2, brightness, across, upward)
            } else {
                // Until the picture arrives.
                uniforms.surroundings = SIMD4(0, 1, 0, 0)
            }
        case .passthrough:
            uniforms.surroundings = SIMD4(3, brightness, 0, 0)
        }

        encoder.setFragmentTexture(blankTexture, index: SceneTextureSlot.cameraLuma)
        encoder.setFragmentTexture(blankTexture, index: SceneTextureSlot.cameraChroma)
        encoder.setFragmentTexture(imageTexture, index: SceneTextureSlot.surroundings)
    }

    /// Passthrough: hands a frame from the camera to the shader, in place of the blank one the
    /// surroundings were given. `intrinsics` are the camera's focal lengths and principal point
    /// as fractions of the image, and `cameraFromEye` turns a direction in the eye's axes into
    /// the camera's when it took the frame. `image` carries the textures from one call to the
    /// next, so a frame that is drawn again is wrapped only once.
    func bindCamera(
        _ pixelBuffer: CVPixelBuffer, intrinsics: SIMD4<Float>, cameraFromEye: simd_float3x3, image: inout VideoImage?,
        to encoder: any MTLRenderCommandEncoder, uniforms: inout SceneUniforms, held: HeldImages
    ) {
        if image?.pixelBuffer !== pixelBuffer {
            image = makeImage(pixelBuffer)
        }
        guard let image,
              let luma = CVMetalTextureGetTexture(image.luma),
              let chroma = CVMetalTextureGetTexture(image.chroma)
        else { return }

        held.images.append(image)
        encoder.setFragmentTexture(luma, index: SceneTextureSlot.cameraLuma)
        encoder.setFragmentTexture(chroma, index: SceneTextureSlot.cameraChroma)
        uniforms.camera = intrinsics
        let isVideoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        uniforms.cameraFormat = SIMD4(isVideoRange ? 1 : 0, 0, 0, 0)
        // The camera's picture is drawn where the camera was pointing when it took it, which
        // keeps the room still even though the picture is a little old.
        uniforms.cameraFromEye = simd_float4x4(rotation: cameraFromEye)
    }
}
