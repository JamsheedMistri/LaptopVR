import CoreVideo
import Foundation
import VRProtocol
import VRVideo

/// What the phone's camera sees, for drawing passthrough in recordings and screenshots.
///
/// The phone sends its camera's picture only while the scene asks for it, which the Mac does
/// while it is recording a view that looks through the camera. Every frame that arrives is
/// decoded, so the decoder always has the frames the next one builds on, but one is kept only
/// while it is wanted: a picture left over from an earlier recording must not turn up in a
/// later one.
final class CameraFeed: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        /// Focal lengths and principal point (fx, fy, cx, cy) as fractions of the image size.
        let intrinsics: SIMD4<Float>
        /// Quaternion from the camera's axes, when the frame was taken, to the surroundings'.
        let surroundingsFromCamera: SIMD4<Float>
    }

    private let send: @Sendable (WireFrame) -> Void
    private let queue = DispatchQueue(label: "laptopvr.camera", qos: .userInitiated)

    // Touched only on `queue`.
    private let decoder = VideoDecoder()
    private var lastKeyframeRequestNanos: UInt64 = 0

    private let lock = NSLock()
    // Guarded by `lock`.
    private var isWanted = false
    private var frame: Frame?

    /// `send` reaches the phone.
    init(send: @escaping @Sendable (WireFrame) -> Void) {
        self.send = send
    }

    /// The newest frame, if frames are wanted and one has arrived since they were.
    var latestFrame: Frame? {
        lock.withLock { frame }
    }

    func setWanted(_ wanted: Bool) {
        lock.withLock {
            isWanted = wanted
            if !wanted {
                frame = nil
            }
        }
    }

    /// A new link starts with a keyframe, and the frames from before it are of no use.
    func resetForNewLink() {
        lock.withLock { frame = nil }
        queue.async { [self] in decoder.invalidate() }
    }

    /// Takes a camera frame from the phone. Called on the link's queue.
    func handle(_ wireFrame: WireFrame) {
        guard let packet = try? CameraPacket(frame: wireFrame) else { return }
        queue.async { [self] in
            switch decoder.decode(packet.video) {
            case .frame(let pixelBuffer):
                lock.withLock {
                    guard isWanted else { return }
                    frame = Frame(
                        pixelBuffer: pixelBuffer,
                        intrinsics: packet.intrinsics,
                        surroundingsFromCamera: packet.surroundingsFromCamera)
                }
            case .needsKeyframe:
                // Every frame fails until the keyframe arrives; one request is enough.
                let now = hostTimeNanos()
                if now - lastKeyframeRequestNanos > 250_000_000 {
                    lastKeyframeRequestNanos = now
                    send(.keyframeRequest(stream: LaptopVRProtocol.cameraStream))
                }
            }

            // Acknowledge failures too: the phone limits how many frames are unacknowledged.
            send(VideoAck(
                stream: LaptopVRProtocol.cameraStream,
                frameID: packet.video.frameID,
                captureTimeNanos: packet.video.captureTimeNanos,
                decodeMicros: 0
            ).frame())
        }
    }
}
