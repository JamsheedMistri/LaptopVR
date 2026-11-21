import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers
import VRProtocol

enum CaptureError: LocalizedError {
    case drawing
    case writing(String)

    var errorDescription: String? {
        switch self {
        case .drawing: "The headset view could not be drawn."
        case .writing(let reason): "The file could not be written: \(reason)"
        }
    }
}

/// Records what the wearer sees to a movie, and takes pictures of it.
///
/// Everything is drawn on the Mac by `ViewRenderer`. This class keeps what the renderer draws
/// from (the scene, the newest view from the phone, the newest frames of the screens and of the
/// phone's camera) and runs the clock of a recording. All drawing and writing happen on its own
/// queue.
final class ViewRecorder: @unchecked Sendable {
    private static let movieSize = (width: 1920, height: 1080)
    private static let pictureSize = (width: 2560, height: 1440)
    private static let framesPerSecond = 60
    private static let movieBitsPerSecond = 12_000_000
    /// How quickly a recording follows the head. The phone's views arrive on its own clock, not
    /// this one's; easing toward the newest one hides the frames where the two fall out of step.
    private static let smoothingSeconds = 0.04
    /// Longest wait for the camera's first frame when the view looks through it. The phone
    /// starts sending them only when a recording or a screenshot is asked for.
    private static let cameraWaitNanos: UInt64 = 1_000_000_000

    /// A movie being written.
    private final class Movie: @unchecked Sendable {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let createdNanos = hostTimeNanos()
        /// When the first frame was drawn, which is where the movie's clock starts.
        var startNanos: UInt64?
        /// When the newest frame was drawn, counted from the start, and the view it showed.
        var lastFrameNanos: UInt64?
        var lastPose: ViewPose?

        init(url: URL, writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.url = url
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        }
    }

    private let camera: CameraFeed
    private let frames: @Sendable () -> [UInt16: CVPixelBuffer]
    private let queue = DispatchQueue(label: "laptopvr.recorder", qos: .userInitiated)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var scene = SceneState()
    private var pose: ViewPose?
    private var surroundings: AssetMessage?
    private var fieldOfViewDegrees = 110.0
    private var onFailure: (@Sendable (String) -> Void)?

    // Touched only on `queue`.
    private var renderer: ViewRenderer?
    private var movie: Movie?
    private var timer: (any DispatchSourceTimer)?

    /// `frames` returns the newest captured frame of every screen. It is called on the
    /// recorder's queue.
    init(camera: CameraFeed, frames: @escaping @Sendable () -> [UInt16: CVPixelBuffer]) {
        self.camera = camera
        self.frames = frames
    }

    // MARK: - Inputs, from any thread

    func setScene(_ scene: SceneState) {
        lock.withLock { self.scene = scene }
    }

    /// The picture the scene's surroundings may refer to.
    func setSurroundings(_ asset: AssetMessage?) {
        lock.withLock { surroundings = asset }
    }

    func setFieldOfView(degrees: Double) {
        lock.withLock { fieldOfViewDegrees = degrees }
    }

    /// Takes the phone's report of where the wearer is looking.
    func handle(_ frame: WireFrame) {
        guard let pose = try? ViewPose(frame: frame) else { return }
        lock.withLock { self.pose = pose }
    }

    /// Called if a recording stops by itself, for example because the disk is full.
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { onFailure = handler }
    }

    // MARK: - Recording

    func startRecording(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try begin(url) })
            }
        }
    }

    /// Ends the recording and returns the finished movie, or nil if there was none.
    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish { continuation.resume(returning: $0) }
            }
        }
    }

    /// Ends a recording in progress and waits a short while for its file to be completed. For
    /// use while the app is exiting, when nothing can be awaited.
    func finishNow() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            finish { _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private func begin(_ url: URL) throws {
        guard movie == nil else { return }
        _ = try preparedRenderer()

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Self.movieSize.width,
            AVVideoHeightKey: Self.movieSize.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.movieBitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
            ],
        ]
        let attributes = ViewRenderer.targetAttributes(width: Self.movieSize.width, height: Self.movieSize.height)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Written in pieces, so a recording cut short by a crash still plays up to that point.
        writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CaptureError.writing("this Mac cannot encode the recording.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else {
            throw CaptureError.writing("this Mac cannot encode the recording.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureError.writing(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)
        movie = Movie(url: url, writer: writer, input: input, adaptor: adaptor)

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Double(Self.framesPerSecond), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.recordFrame()
        }
        timer.resume()
        self.timer = timer
    }

    /// Draws the view as it is now and appends it to the movie. Runs on `queue`.
    private func recordFrame() {
        guard let movie, let renderer else { return }
        guard movie.writer.status == .writing else {
            // The writer gave up, for example because the disk filled.
            let reason = movie.writer.error?.localizedDescription ?? "unknown error"
            finish { _ in }
            lock.withLock { onFailure }?(CaptureError.writing(reason).localizedDescription)
            return
        }
        // The encoder is behind; this frame is skipped rather than queued.
        guard movie.input.isReadyForMoreMediaData, let pool = movie.adaptor.pixelBufferPool else { return }

        let now = hostTimeNanos()
        let (view, surroundings) = currentView()
        // A movie that looks through the camera starts when the camera's picture gets here,
        // rather than with a moment of black.
        if movie.startNanos == nil, view.lacksCamera, now - movie.createdNanos < Self.cameraWaitNanos { return }
        let start = movie.startNanos ?? now
        let sinceStart = now - start
        if let last = movie.lastFrameNanos, sinceStart <= last { return }

        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let pixelBuffer = created else { return }

        var eased = view
        if let previous = movie.lastPose, let last = movie.lastFrameNanos {
            let seconds = Double(sinceStart - last) / 1_000_000_000
            eased.pose = Self.ease(previous, toward: view.pose, by: Float(1 - exp(-seconds / Self.smoothingSeconds)))
        }
        guard renderer.draw(eased, surroundings: surroundings, into: pixelBuffer) else { return }
        movie.lastPose = eased.pose

        // The picture holds sRGB values. Saying so lets the encoder convert them properly.
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)

        let time = CMTime(value: CMTimeValue(sinceStart), timescale: 1_000_000_000)
        if movie.adaptor.append(pixelBuffer, withPresentationTime: time) {
            movie.startNanos = start
            movie.lastFrameNanos = sinceStart
        }
    }

    /// Stops the clock and closes the movie. Runs on `queue`; `completion` may run elsewhere.
    private func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        timer?.cancel()
        timer = nil
        renderer?.releaseFrames()
        guard let movie else {
            completion(nil)
            return
        }
        self.movie = nil

        guard movie.startNanos != nil else {
            // Stopped before its first frame, as it can be while waiting for the camera's
            // picture. There is no movie.
            movie.writer.cancelWriting()
            try? FileManager.default.removeItem(at: movie.url)
            completion(nil)
            return
        }
        guard movie.writer.status == .writing else {
            // Already failed. What reached the disk before that may still play.
            completion(FileManager.default.fileExists(atPath: movie.url.path) ? movie.url : nil)
            return
        }
        movie.input.markAsFinished()
        movie.writer.finishWriting {
            completion(movie.writer.status == .completed ? movie.url : nil)
        }
    }

    // MARK: - Pictures

    /// Draws the view as it is now and saves it as a PNG.
    func takeScreenshot(to url: URL) async throws {
        // A view that looks through the camera waits a moment for the camera's picture.
        let deadline = ContinuousClock.now + .nanoseconds(Int(Self.cameraWaitNanos))
        while lacksCamera, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let picture = try drawPicture()
                    // Compressing takes long enough to cost a recording frames; do it elsewhere.
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try picture.writePNG(to: url) })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on `queue`.
    private func drawPicture() throws -> Picture {
        let renderer = try preparedRenderer()
        let attributes = ViewRenderer.targetAttributes(width: Self.pictureSize.width, height: Self.pictureSize.height)

        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Self.pictureSize.width, Self.pictureSize.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &created)
        let (view, surroundings) = currentView()
        guard let pixelBuffer = created, renderer.draw(view, surroundings: surroundings, into: pixelBuffer) else {
            throw CaptureError.drawing
        }
        if movie == nil {
            renderer.releaseFrames()
        }
        guard let picture = Picture(copying: pixelBuffer) else { throw CaptureError.drawing }
        return picture
    }

    // MARK: - What to draw

    /// Runs on `queue`.
    private func preparedRenderer() throws -> ViewRenderer {
        if let renderer { return renderer }
        let created = try ViewRenderer()
        renderer = created
        return created
    }

    private func currentView() -> (view: ViewRenderer.View, surroundings: AssetMessage?) {
        let (scene, pose, surroundings, fieldOfView) = lock.withLock {
            (self.scene, self.pose, self.surroundings, self.fieldOfViewDegrees)
        }
        // Until the phone says otherwise, look straight at the focused screen.
        let ahead = scene.screens.first { $0.id == scene.focusedScreen }
            .map { SIMD2(Float($0.centerX), Float($0.centerY)) } ?? SIMD2()
        let view = ViewRenderer.View(
            scene: scene, pose: pose ?? ViewPose(focus: ahead), frames: frames(),
            camera: scene.environment.kind == .passthrough ? camera.latestFrame : nil,
            fieldOfViewDegrees: fieldOfView)
        return (view, surroundings)
    }

    /// True while the scene looks through the camera and no picture from it has arrived.
    private var lacksCamera: Bool {
        lock.withLock { scene.environment.kind == .passthrough } && camera.latestFrame == nil
    }

    /// A view part of the way from one to another.
    private static func ease(_ from: ViewPose, toward to: ViewPose, by amount: Float) -> ViewPose {
        func turn(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
            guard simd_length(a) > 0.5, simd_length(b) > 0.5 else { return b }
            return simd_slerp(simd_quatf(vector: simd_normalize(a)), simd_quatf(vector: simd_normalize(b)), amount).vector
        }
        return ViewPose(
            sceneFromEye: turn(from.sceneFromEye, to.sceneFromEye),
            surroundingsFromEye: turn(from.surroundingsFromEye, to.surroundingsFromEye),
            headPosition: from.headPosition + (to.headPosition - from.headPosition) * amount,
            focus: from.focus + (to.focus - from.focus) * amount)
    }
}

/// The pixels of a finished picture, copied out of the buffer they were drawn into.
private struct Picture: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    /// Blue, green, red, and an unused byte for every pixel.
    let pixels: Data

    init?(copying pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        pixels = Data(bytes: base, count: bytesPerRow * height)
    }

    func writePNG(to url: URL) throws {
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CaptureError.drawing }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.writing("the picture could not be saved to \(url.path).")
        }
    }
}
