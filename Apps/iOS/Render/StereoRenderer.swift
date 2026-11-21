import CoreVideo
import Metal
import QuartzCore
import simd
import VRProtocol

extension RendererError: LocalizedError {
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
        var surroundingsImage: SurroundingsImage?
        var onView: (@Sendable (ViewPose) -> Void)?
        var onCameraFrame: (@Sendable (Passthrough.Frame, SIMD4<Float>) -> Void)?
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
        var lastReportTime: CFTimeInterval = 0
    }

    private static let toastDuration: CFTimeInterval = 2.2
    /// Least time between two reports of the view to the Mac: 60 a second, with room for a
    /// refresh that arrives a little early.
    private static let reportInterval: CFTimeInterval = 0.0155
    /// Eyes sit above and ahead of the neck they pivot on. Used when position is not tracked,
    /// so that turning the head still shifts the view slightly, as it does in life.
    private static let neck = SIMD3<Float>(0, 0.075, -0.08)

    private let frames: FrameStore
    private let tracker: HeadTracker
    private let passthrough: Passthrough

    private let resources: SceneResources
    private let pipeline: any MTLRenderPipelineState
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

        resources = try SceneResources()
        pipeline = try resources.makePipeline(fragment: "stereoFragment")
        guard let hudPanel = HUDPanel(device: resources.device) else { throw RendererError.metalUnavailable }
        self.hudPanel = hudPanel
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
            guard let image = resources.makeSurroundingsImage(id: id, data: data) else { return }
            lock.withLock { inputs.surroundingsImage = image }
        }
    }

    /// Where the wearer is looking, reported many times a second while a session runs, on the
    /// render thread.
    func setViewHandler(_ handler: (@Sendable (ViewPose) -> Void)?) {
        lock.withLock { inputs.onView = handler }
    }

    /// Every frame of the passthrough camera, once, as it is first drawn, on the render thread.
    /// With it comes the quaternion that turns a direction in the camera's axes into the axes
    /// of the surroundings, which is how `CameraPacket` describes where the camera pointed.
    func setCameraHandler(_ handler: (@Sendable (Passthrough.Frame, SIMD4<Float>) -> Void)?) {
        lock.withLock { inputs.onCameraFrame = handler }
    }

    var metrics: Metrics {
        lock.withLock { currentMetrics }
    }

    // MARK: - Running

    /// Starts drawing into `layer` at the display's refresh rate.
    @MainActor
    func start(layer: CAMetalLayer) {
        stop()
        layer.device = resources.device
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

        if scene.mode == .follow, !screens.isEmpty {
            follow(
                forward: forward, screens: screens, angle: Float(scene.screenAngleDegrees) * .pi / 180,
                curvature: Float(scene.curvature), profile: inputs.profile)
            view.anchorPosition = position
        }
        view.headOffset = position - view.anchorPosition

        // Uniforms.
        let glassWidth = Float(update.drawable.texture.width)
        let glassHeight = Float(update.drawable.texture.height)
        let profile = inputs.profile
        let sceneFromWorld = view.anchor.rotation.transpose

        let sceneFromEye = sceneFromWorld * worldFromEye
        let surroundingsFromEye = Bearing(azimuth: view.surroundingsAzimuth).rotation.transpose * worldFromEye
        let headInScene = sceneFromWorld * view.headOffset

        if scene.sessionActive, let onView = inputs.onView, presentTime - view.lastReportTime >= Self.reportInterval {
            view.lastReportTime = presentTime
            onView(ViewPose(
                sceneFromEye: simd_quatf(sceneFromEye).vector,
                surroundingsFromEye: simd_quatf(surroundingsFromEye).vector,
                headPosition: headInScene,
                focus: view.focus))
        }

        var uniforms = SceneUniforms()
        uniforms.sceneFromEye = simd_float4x4(rotation: sceneFromEye)
        uniforms.surroundingsFromEye = simd_float4x4(rotation: surroundingsFromEye)
        uniforms.headPosition = SIMD4(headInScene, 0)
        uniforms.viewport = SIMD4(
            glassWidth, glassHeight, inputs.pixelsPerMeter,
            profile.lensHeight(screenHeight: glassHeight / inputs.pixelsPerMeter))
        uniforms.lens = SIMD4(profile.lensSeparation, profile.screenToLens, profile.k1, profile.k2)
        uniforms.optics = SIMD4(tan(profile.fieldOfView * .pi / 180), profile.lensSeparation, 0, 0)
        uniforms.setLayout(scene, screenCount: screens.count, focus: view.focus)

        guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = update.drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)

        let held = HeldImages()
        bindScreens(screens, to: encoder, uniforms: &uniforms, held: held, presentTime: presentTime)
        resources.bindSurroundings(
            scene.environment, image: inputs.surroundingsImage, to: encoder, uniforms: &uniforms)
        bindCamera(
            cameraFrame, worldFromEye: worldFromEye, onFrame: inputs.onCameraFrame,
            to: encoder, uniforms: &uniforms, held: held)
        bindHUD(inputs, hasScreens: !screens.isEmpty, now: now, to: encoder, uniforms: &uniforms)

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
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
        _ screens: [ScreenDescriptor], to encoder: any MTLRenderCommandEncoder, uniforms: inout SceneUniforms,
        held: HeldImages, presentTime: CFTimeInterval
    ) {
        let latest = frames.latest()
        let fresh = resources.bindScreens(
            screens, frames: latest.mapValues(\.pixelBuffer), images: &screenImages,
            to: encoder, uniforms: &uniforms, held: held)

        for screen in screens where fresh.contains(screen.id) {
            // First refresh showing this frame: note how long it waited.
            guard let frame = latest[screen.id] else { continue }
            let waited = (presentTime - frame.decodedAt) * 1000
            presentMillis = presentMillis == 0 ? waited : presentMillis * 0.9 + waited * 0.1
        }
    }

    /// Passthrough: hands the camera's newest picture to the shader, and to `onFrame` the first
    /// time it is drawn.
    private func bindCamera(
        _ cameraFrame: Passthrough.Frame?, worldFromEye: simd_float3x3,
        onFrame: (@Sendable (Passthrough.Frame, SIMD4<Float>) -> Void)?,
        to encoder: any MTLRenderCommandEncoder, uniforms: inout SceneUniforms, held: HeldImages
    ) {
        guard let cameraFrame else {
            cameraImage = nil
            return
        }
        let isNew = cameraImage?.pixelBuffer !== cameraFrame.pixelBuffer
        let worldFromCamera = simd_float3x3(cameraFrame.worldFromCamera)
        resources.bindCamera(
            cameraFrame.pixelBuffer, intrinsics: cameraFrame.intrinsics,
            cameraFromEye: worldFromCamera.transpose * worldFromEye,
            image: &cameraImage, to: encoder, uniforms: &uniforms, held: held)

        if isNew, let onFrame {
            let surroundingsFromWorld = Bearing(azimuth: view.surroundingsAzimuth).rotation.transpose
            onFrame(cameraFrame, simd_quatf(surroundingsFromWorld * worldFromCamera).vector)
        }
    }

    private func bindHUD(
        _ inputs: Inputs, hasScreens: Bool, now: CFTimeInterval, to encoder: any MTLRenderCommandEncoder,
        uniforms: inout SceneUniforms
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
        encoder.setFragmentTexture(hudPanel.texture, index: SceneTextureSlot.hud)
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
