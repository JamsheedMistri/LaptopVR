import CoreVideo
import Metal
import MetalKit
import QuartzCore
import simd
import VRProtocol

enum RendererError: LocalizedError {
    case metalUnavailable
    case shader(String)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: "This iPhone cannot draw the headset view."
        case .shader(let message): "The headset view could not be prepared: \(message)"
        }
    }
}

/// Draws the stereo view. Runs on its own thread, driven by the display: each refresh it reads
/// the newest decoded frames and the head pose predicted for the moment the refresh reaches the
/// glass, and draws once. Video and head tracking are independent, so the view keeps turning
/// smoothly at the display's rate even when the Mac sends nothing.
final class StereoRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Metrics: Sendable {
        var framesPerSecond = 0.0
        /// Average time from a frame being decoded to it reaching the glass.
        var presentMillis = 0.0
    }

    /// Mirrors `Uniforms` in StereoShader.msl. Only 16-byte-aligned members, so the two layouts
    /// agree without padding rules coming into it.
    private struct Uniforms {
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
        var hud = SIMD4<Float>()
        var screenRect = InlineArray<6, SIMD4<Float>>(repeating: SIMD4())
        var screenImage = InlineArray<6, SIMD4<Float>>(repeating: SIMD4())
    }

    /// Texture slots, matching the shader's arguments.
    private enum Slot {
        static let screenLuma = 0
        static let screenChroma = 6
        static let cameraLuma = 12
        static let cameraChroma = 13
        static let surroundings = 14
        static let hud = 15
    }

    /// Everything other threads hand to the renderer.
    private struct Inputs {
        var scene = SceneState()
        var profile = ViewerProfile.cardboardV2
        var side = LandscapeSide.right
        var pixelsPerMeter: Float = 18_110
        var recenterRequested = false
        var message: HUDContent?
        var toast: (text: String, shownAt: CFTimeInterval)?
        var statsLines: [String] = []
        var surroundingsImage: (id: String, texture: MTLTexture)?
    }

    /// A decoded frame's two planes as Metal textures.
    private struct VideoImage {
        let pixelBuffer: CVPixelBuffer
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
    }

    /// Keeps textures alive until the GPU has finished the frame that uses them.
    private final class Held: @unchecked Sendable {
        var images: [VideoImage] = []
    }

    /// Where the screens are relative to the world, carried from frame to frame.
    private struct ViewState {
        var isInitialized = false
        /// Direction the scene's centre lies in. Set by recentering; dragged along in Follow mode.
        var anchor = Bearing()
        var anchorPosition = SIMD3<Float>()
        var surroundingsAzimuth: Float = 0
        /// Canvas point that sits at the scene's centre. Eases toward the focused screen.
        var focus = SIMD2<Float>()
        var headOffset = SIMD3<Float>()
        var isPositional = false
        var trackedPosition: SIMD3<Float>?
        var wasSessionActive = false
        var lastPresentTime: CFTimeInterval = 0
    }

    private static let toastDuration: CFTimeInterval = 2.2
    /// Eyes sit above and ahead of the neck they pivot on. Used when position is not tracked,
    /// so that turning the head still shifts the view slightly, as it does in life.
    private static let neck = SIMD3<Float>(0, 0.075, -0.08)

    private let frames: FrameStore
    private let tracker: HeadTracker
    private let passthrough: Passthrough

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let blankTexture: MTLTexture
    private let hudPanel: HUDPanel

    private let lock = NSLock()
    // Guarded by `lock`.
    private var inputs = Inputs()
    private var currentMetrics = Metrics()
    private var thread: Thread?
    private var handoff: LinkHandoff?

    // Touched only on the render thread.
    private var view = ViewState()
    private var screenImages: [UInt16: VideoImage] = [:]
    private var cameraImage: VideoImage?
    private var frameCount = 0
    private var countingSince: CFTimeInterval = 0
    private var presentMillis = 0.0

    init(frames: FrameStore, tracker: HeadTracker, passthrough: Passthrough) throws {
        self.frames = frames
        self.tracker = tracker
        self.passthrough = passthrough

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let hudPanel = HUDPanel(device: device),
              let blankTexture = device.makeTexture(descriptor: .texture2DDescriptor(
                  pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))
        else { throw RendererError.metalUnavailable }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RendererError.metalUnavailable }

        // The shader ships as source and is compiled here, so building the app does not need
        // Xcode's separate Metal toolchain.
        guard let url = Bundle.main.url(forResource: "StereoShader", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw RendererError.shader("StereoShader.msl is missing from the app.") }

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "stereoFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        self.hudPanel = hudPanel
        self.blankTexture = blankTexture
        self.sampler = sampler
        textureCache = cache
    }

    // MARK: - Inputs, from any thread

    func setScene(_ scene: SceneState) {
        lock.withLock { inputs.scene = scene }
    }

    func setProfile(_ profile: ViewerProfile) {
        lock.withLock { inputs.profile = profile }
    }

    func setDisplay(side: LandscapeSide, pixelsPerMeter: Float) {
        lock.withLock {
            inputs.side = side
            inputs.pixelsPerMeter = pixelsPerMeter
        }
    }

    /// Puts the focused screen straight ahead of wherever the head points now.
    func recenter() {
        lock.withLock { inputs.recenterRequested = true }
    }

    /// Shows a message for as long as it stays set, such as "Waiting for your Mac".
    func setMessage(_ message: HUDContent?) {
        lock.withLock { inputs.message = message }
    }

    /// Shows a message briefly.
    func showToast(_ text: String) {
        lock.withLock { inputs.toast = (text, CACurrentMediaTime()) }
    }

    func setStatsLines(_ lines: [String]) {
        lock.withLock { inputs.statsLines = lines }
    }

    /// Decodes a picture for the surroundings. `id` is what the scene refers to it by.
    func setSurroundingsImage(id: String, data: Data) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let loader = MTKTextureLoader(device: device)
            // Left as encoded, like the video: colours pass through to the glass untouched.
            guard let texture = try? loader.newTexture(data: data, options: [.SRGB: false]) else { return }
            lock.withLock { inputs.surroundingsImage = (id, texture) }
        }
    }

    var metrics: Metrics {
        lock.withLock { currentMetrics }
    }

    // MARK: - Running

    /// Starts drawing into `layer` at the display's refresh rate.
    @MainActor
    func start(layer: CAMetalLayer) {
        stop()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // The Mac sends sRGB; say so, and the system maps it to the iPhone's wider gamut.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        // One frame of latency is the least the system offers.
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

        let handoff = LinkHandoff(link: link)
        let thread = Thread {
            handoff.link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            handoff.link.invalidate()
            handoff.finished.signal()
        }
        thread.name = "laptopvr.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        lock.withLock {
            self.thread = thread
            self.handoff = handoff
            inputs.recenterRequested = true
        }
    }

    /// Stops drawing and waits for the render thread to finish, so a later start cannot overlap.
    func stop() {
        let (thread, handoff) = lock.withLock { () -> (Thread?, LinkHandoff?) in
            defer {
                self.thread = nil
                self.handoff = nil
            }
            return (self.thread, self.handoff)
        }
        thread?.cancel()
        handoff?.finished.wait()
    }

    /// Carries the display link onto the render thread.
    private final class LinkHandoff: @unchecked Sendable {
        let link: CAMetalDisplayLink
        let finished = DispatchSemaphore(value: 0)

        init(link: CAMetalDisplayLink) {
            self.link = link
        }
    }

    // MARK: - Drawing

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            draw(update)
        }
    }

    private func draw(_ update: CAMetalDisplayLink.Update) {
        let now = CACurrentMediaTime()
        let presentTime = update.targetPresentationTimestamp
        let inputs = lock.withLock { () -> Inputs in
            defer { self.inputs.recenterRequested = false }
            return self.inputs
        }
        let scene = inputs.scene
        let screens = Array(scene.screens.prefix(LaptopVRProtocol.maxScreens))
        let step = Float(min(max(presentTime - view.lastPresentTime, 0), 0.1))
        view.lastPresentTime = presentTime

        // Head pose, predicted for when this frame reaches the glass.
        let deviceOrientation = tracker.worldFromDevice(at: presentTime)
        let worldFromEye = deviceOrientation.map { simd_float3x3($0) * inputs.side.deviceFromView }
            ?? matrix_identity_float3x3
        let forward = worldFromEye * SIMD3<Float>(0, 0, -1)

        let cameraFrame = scene.environment.kind == .passthrough ? passthrough.latestFrame : nil
        let position = headPosition(worldFromEye: worldFromEye, tracked: cameraFrame?.position, step: step)

        let sessionStarted = scene.sessionActive && !view.wasSessionActive
        view.wasSessionActive = scene.sessionActive
        let recentering = deviceOrientation != nil
            && (inputs.recenterRequested || sessionStarted || !view.isInitialized)
        if recentering {
            let looking = Bearing(of: forward)
            // Tilt is followed so the screens can sit overhead when lying down, short of vertical.
            view.anchor = Bearing(azimuth: looking.azimuth, elevation: min(max(looking.elevation, -1.2), 1.2))
            view.surroundingsAzimuth = looking.azimuth
            view.anchorPosition = position
            view.isInitialized = true
        }

        // The focused screen glides to the centre rather than jumping there.
        let focusTarget = screens.first { $0.id == scene.focusedScreen }
            .map { SIMD2(Float($0.centerX), Float($0.centerY)) } ?? SIMD2()
        view.focus = recentering ? focusTarget : view.focus + (focusTarget - view.focus) * (1 - exp(-step / 0.07))

        let angle = Float(scene.screenAngleDegrees) * .pi / 180
        let distance = Float(scene.distanceMeters)
        let curvature = Float(scene.curvature)

        if scene.mode == .follow, !screens.isEmpty {
            follow(forward: forward, screens: screens, angle: angle, curvature: curvature, profile: inputs.profile)
            view.anchorPosition = position
        }
        view.headOffset = position - view.anchorPosition

        // Uniforms.
        let glassWidth = Float(update.drawable.texture.width)
        let glassHeight = Float(update.drawable.texture.height)
        let profile = inputs.profile
        let sceneFromWorld = view.anchor.rotation.transpose

        var uniforms = Uniforms()
        uniforms.sceneFromEye = simd_float4x4(rotation: sceneFromWorld * worldFromEye)
        uniforms.surroundingsFromEye = simd_float4x4(
            rotation: Bearing(azimuth: view.surroundingsAzimuth).rotation.transpose * worldFromEye)
        uniforms.headPosition = SIMD4(sceneFromWorld * view.headOffset, 0)
        uniforms.viewport = SIMD4(
            glassWidth, glassHeight, inputs.pixelsPerMeter,
            profile.lensHeight(screenHeight: glassHeight / inputs.pixelsPerMeter))
        uniforms.lens = SIMD4(profile.lensSeparation, profile.screenToLens, profile.k1, profile.k2)
        uniforms.optics = SIMD4(tan(profile.fieldOfView * .pi / 180), profile.lensSeparation, 0, 0)
        uniforms.layout = SIMD4(distance, distance * angle, curvature, Float(screens.count))
        uniforms.focus = SIMD4(view.focus.x, view.focus.y, 0.012, 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = update.drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let held = Held()
        bindScreens(screens, to: encoder, uniforms: &uniforms, held: held, presentTime: presentTime)
        bindSurroundings(
            scene.environment, image: inputs.surroundingsImage, cameraFrame: cameraFrame,
            worldFromEye: worldFromEye, to: encoder, uniforms: &uniforms, held: held)
        bindHUD(inputs, hasScreens: !screens.isEmpty, now: now, to: encoder, uniforms: &uniforms)

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(held) {}
        }
        commandBuffer.present(update.drawable)
        commandBuffer.commit()

        updateMetrics(now: now)
    }

    // MARK: - Head and scene placement

    private func headPosition(worldFromEye: simd_float3x3, tracked: SIMD3<Float>?, step: Float) -> SIMD3<Float> {
        var position = worldFromEye * Self.neck
        if let tracked {
            // Camera-rate positions, smoothed so the screens do not move in steps.
            let smoothed = view.trackedPosition.map { $0 + (tracked - $0) * (1 - exp(-step / 0.03)) } ?? tracked
            view.trackedPosition = smoothed
            position = smoothed
        } else {
            view.trackedPosition = nil
        }

        let isPositional = tracked != nil
        if isPositional != view.isPositional {
            // The two sources measure from different origins. Carry the head's offset from the
            // screens across the switch so nothing jumps.
            view.isPositional = isPositional
            view.anchorPosition = position - view.headOffset
        }
        return position
    }

    /// Follow mode: when the head turns past the point where the screens would start to leave
    /// the view, the scene turns with it.
    private func follow(
        forward: SIMD3<Float>, screens: [ScreenDescriptor], angle: Float, curvature: Float, profile: ViewerProfile
    ) {
        var left = Float.infinity, right = -Float.infinity, bottom = Float.infinity, top = -Float.infinity
        for screen in screens {
            left = min(left, Float(screen.centerX - screen.width / 2))
            right = max(right, Float(screen.centerX + screen.width / 2))
            bottom = min(bottom, Float(screen.centerY - screen.height / 2))
            top = max(top, Float(screen.centerY + screen.height / 2))
        }

        // The angle at which a point on the canvas appears: its arc on a curved surface, less
        // toward the edges of a flat one.
        func across(_ x: Float) -> Float {
            let arc = (x - view.focus.x) * angle
            return atan(arc) + (arc - atan(arc)) * curvature
        }
        func upward(_ y: Float) -> Float {
            atan((y - view.focus.y) * angle)
        }
        func range(_ low: Float, _ high: Float, margin: Float) -> ClosedRange<Float> {
            // A screen smaller than the view stays centred.
            low + margin < high - margin ? (low + margin)...(high - margin) : ((low + high) / 2)...((low + high) / 2)
        }

        let viewHalfAngle = min(profile.fieldOfView, 40) * .pi / 180
        let horizontal = range(across(left), across(right), margin: 0.7 * viewHalfAngle)
        let vertical = range(upward(bottom), upward(top), margin: 0.45 * viewHalfAngle)

        let looking = Bearing(of: view.anchor.rotation.transpose * forward)
        view.anchor.azimuth += looking.azimuth - min(max(looking.azimuth, horizontal.lowerBound), horizontal.upperBound)
        view.anchor.elevation += looking.elevation - min(max(looking.elevation, vertical.lowerBound), vertical.upperBound)
        view.anchor.elevation = min(max(view.anchor.elevation, -1.3), 1.3)
    }

    // MARK: - Textures

    private func bindScreens(
        _ screens: [ScreenDescriptor], to encoder: any MTLRenderCommandEncoder, uniforms: inout Uniforms,
        held: Held, presentTime: CFTimeInterval
    ) {
        let latest = frames.latest()
        var current: [UInt16: VideoImage] = [:]

        for index in 0..<LaptopVRProtocol.maxScreens {
            var luma = blankTexture
            var chroma = blankTexture

            if index < screens.count {
                let screen = screens[index]
                uniforms.screenRect[index] = SIMD4(
                    Float(screen.centerX), Float(screen.centerY), Float(screen.width), Float(screen.height))

                if let frame = latest[screen.id] {
                    var image = screenImages[screen.id]
                    if image?.pixelBuffer !== frame.pixelBuffer {
                        image = makeImage(frame.pixelBuffer)
                        // First refresh showing this frame: note how long it waited.
                        let waited = (presentTime - frame.decodedAt) * 1000
                        presentMillis = presentMillis == 0 ? waited : presentMillis * 0.9 + waited * 0.1
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
            encoder.setFragmentTexture(luma, index: Slot.screenLuma + index)
            encoder.setFragmentTexture(chroma, index: Slot.screenChroma + index)
        }
        screenImages = current
    }

    private func bindSurroundings(
        _ environment: EnvironmentSettings, image: (id: String, texture: MTLTexture)?, cameraFrame: Passthrough.Frame?,
        worldFromEye: simd_float3x3, to encoder: any MTLRenderCommandEncoder, uniforms: inout Uniforms, held: Held
    ) {
        func color(_ color: RGBColor) -> SIMD4<Float> {
            SIMD4(Float(color.red), Float(color.green), Float(color.blue), 1)
        }
        uniforms.primaryColor = color(environment.primaryColor)
        uniforms.secondaryColor = color(environment.secondaryColor)
        let brightness = Float(1 - min(max(environment.dimming, 0), 1))

        var imageTexture = blankTexture
        var cameraLuma = blankTexture
        var cameraChroma = blankTexture

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
            if let cameraFrame {
                if cameraImage?.pixelBuffer !== cameraFrame.pixelBuffer {
                    cameraImage = makeImage(cameraFrame.pixelBuffer)
                }
                if let cameraImage,
                   let luma = CVMetalTextureGetTexture(cameraImage.luma),
                   let chroma = CVMetalTextureGetTexture(cameraImage.chroma) {
                    cameraLuma = luma
                    cameraChroma = chroma
                    held.images.append(cameraImage)
                    uniforms.camera = cameraFrame.intrinsics
                    // The camera's picture is drawn where the camera was pointing when it took
                    // it, which keeps the room still even though the picture is a little old.
                    uniforms.cameraFromEye = simd_float4x4(
                        rotation: simd_float3x3(cameraFrame.worldFromCamera).transpose * worldFromEye)
                }
            }
        }
        if environment.kind != .passthrough {
            cameraImage = nil
        }

        encoder.setFragmentTexture(cameraLuma, index: Slot.cameraLuma)
        encoder.setFragmentTexture(cameraChroma, index: Slot.cameraChroma)
        encoder.setFragmentTexture(imageTexture, index: Slot.surroundings)
    }

    private func bindHUD(
        _ inputs: Inputs, hasScreens: Bool, now: CFTimeInterval, to encoder: any MTLRenderCommandEncoder,
        uniforms: inout Uniforms
    ) {
        var content = HUDContent()
        var opacity: Float = 1

        if let toast = inputs.toast, now - toast.shownAt < Self.toastDuration {
            content.title = toast.text
            if inputs.message == nil, !inputs.scene.showStats {
                opacity = min(1, Float(Self.toastDuration - (now - toast.shownAt)) / 0.3)
            }
        } else if let message = inputs.message {
            content = message
        }
        if inputs.scene.showStats {
            content.lines = inputs.statsLines
        }

        if !content.isEmpty {
            hudPanel.show(content)
            // Centred when there is nothing else to look at, otherwise below the middle.
            let aspect = Float(HUDPanel.height) / Float(HUDPanel.width)
            uniforms.hud = SIMD4(hasScreens ? -0.3 : 0, 0.44, 0.44 * aspect, opacity)
        }
        encoder.setFragmentTexture(hudPanel.texture, index: Slot.hud)
    }

    private func makeImage(_ pixelBuffer: CVPixelBuffer) -> VideoImage? {
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

    private func updateMetrics(now: CFTimeInterval) {
        frameCount += 1
        let elapsed = now - countingSince
        guard elapsed >= 1 else { return }
        let metrics = Metrics(framesPerSecond: Double(frameCount) / elapsed, presentMillis: presentMillis)
        lock.withLock { currentMetrics = metrics }
        frameCount = 0
        countingSince = now
    }
}
