import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VRProtocol
import VRVideo

/// Sends what the passthrough camera sees to the Mac, which draws it behind the screens in its
/// recordings and screenshots of the view. Runs only while the Mac asks for it.
///
/// As with the screens' video in the other direction, frames never queue: one is encoded only
/// once the Mac has acknowledged all but a couple of those before it.
final class CameraSender: @unchecked Sendable {
    /// Half the camera's rate. A recording turns the room with the head at its own rate
    /// whatever this is, so it limits only how smoothly things in the room move.
    private static let framesPerSecond = 30
    private static let bitsPerSecond = 8_000_000
    private static let maxFramesInFlight = 2
    /// Frames unacknowledged for this long are taken to be lost.
    private static let stalledAfter: CFTimeInterval = 1

    private let send: @Sendable (WireFrame) -> Void
    private let queue = DispatchQueue(label: "laptopvr.camera", qos: .userInitiated)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var isEnabled = false
    private var framesInFlight = 0
    private var needsKeyframe = true
    private var lastSubmitTime: CFTimeInterval = 0

    // Touched only on `queue`.
    private var encoder: VideoEncoder?
    private var cannotEncode = false
    private var nextFrameID: UInt32 = 0

    init(send: @escaping @Sendable (WireFrame) -> Void) {
        self.send = send
    }

    // MARK: - From any thread

    func setEnabled(_ enabled: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard enabled != isEnabled else { return false }
            isEnabled = enabled
            framesInFlight = 0
            needsKeyframe = true
            return true
        }
        if changed, !enabled {
            // The encoder is only held while it is in use.
            queue.async { [self] in
                encoder = nil
                cannotEncode = false
            }
        }
    }

    /// A new link has seen none of the video, and will acknowledge none of what the old one
    /// was sent.
    func resetForNewLink() {
        lock.withLock {
            framesInFlight = 0
            needsKeyframe = true
        }
    }

    /// The Mac has decoded a frame.
    func acknowledge() {
        lock.withLock { framesInFlight = max(0, framesInFlight - 1) }
    }

    /// The Mac cannot decode what it is being sent until it gets a keyframe.
    func requestKeyframe() {
        lock.withLock { needsKeyframe = true }
    }

    /// Offers a frame from the camera. `surroundingsFromCamera` is as in `CameraPacket`.
    func submit(_ frame: Passthrough.Frame, surroundingsFromCamera: SIMD4<Float>) {
        let now = CACurrentMediaTime()
        let keyframe = lock.withLock { () -> Bool? in
            guard isEnabled, now - lastSubmitTime >= 0.85 / Double(Self.framesPerSecond) else { return nil }
            if framesInFlight >= Self.maxFramesInFlight {
                guard now - lastSubmitTime > Self.stalledAfter else { return nil }
                framesInFlight = 0
                needsKeyframe = true
            }
            defer { needsKeyframe = false }
            framesInFlight += 1
            lastSubmitTime = now
            return needsKeyframe
        }
        guard let keyframe else { return }
        queue.async { [self] in
            encode(frame, surroundingsFromCamera: surroundingsFromCamera, forceKeyframe: keyframe, time: now)
        }
    }

    // MARK: - Encoding, on `queue`

    private func encode(
        _ frame: Passthrough.Frame, surroundingsFromCamera: SIMD4<Float>, forceKeyframe: Bool, time: CFTimeInterval
    ) {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard lock.withLock({ isEnabled }), let (encoder, isNew) = encoder(width: width, height: height) else {
            abandon(wasKeyframe: true)
            return
        }

        let frameID = nextFrameID
        nextFrameID &+= 1
        let isKeyframe = forceKeyframe || isNew
        let codec = encoder.configuration.codec
        let intrinsics = frame.intrinsics
        let submitted = encoder.encode(
            frame.pixelBuffer,
            presentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000),
            forceKeyframe: isKeyframe
        ) { [weak self] encoded in
            guard let self else { return }
            guard let encoded else {
                // The encoder dropped it, so the Mac will never acknowledge it.
                self.abandon(wasKeyframe: isKeyframe)
                return
            }
            let video = VideoPacket(
                stream: LaptopVRProtocol.cameraStream,
                frameID: frameID,
                captureTimeNanos: 0,
                encodeMicros: 0,
                codec: codec,
                isKeyframe: encoded.isKeyframe,
                width: UInt16(clamping: width),
                height: UInt16(clamping: height),
                parameterSets: encoded.parameterSets,
                data: encoded.data
            )
            self.send(CameraPacket(
                video: video, intrinsics: intrinsics, surroundingsFromCamera: surroundingsFromCamera
            ).frame())
        }
        if !submitted {
            // The session is of no use any more, as happens when the app has been in the
            // background. The next frame gets a new one.
            self.encoder = nil
            abandon(wasKeyframe: true)
        }
    }

    /// The encoder for frames of this size, and whether it has yet to encode one.
    private func encoder(width: Int, height: Int) -> (VideoEncoder, isNew: Bool)? {
        if let encoder, encoder.configuration.width == width, encoder.configuration.height == height {
            return (encoder, false)
        }
        guard !cannotEncode else { return nil }
        // H.264, because the encoder's low-latency mode was made for it first.
        let configuration = VideoEncoderConfiguration(
            width: width, height: height, codec: .h264,
            bitsPerSecond: Self.bitsPerSecond, framesPerSecond: Self.framesPerSecond)
        guard let created = try? VideoEncoder(configuration: configuration, isRec709: false) else {
            // Trying again for every frame would only cost time. Wait to be asked afresh.
            cannotEncode = true
            return nil
        }
        encoder = created
        return (created, true)
    }

    /// Undoes the bookkeeping for a frame that was never encoded.
    private func abandon(wasKeyframe: Bool) {
        lock.withLock {
            framesInFlight = max(0, framesInFlight - 1)
            // The frames before it were encoded, so the next one can still build on them. Only
            // a keyframe that was lost has to be asked for again.
            if wasKeyframe {
                needsKeyframe = true
            }
        }
    }
}
