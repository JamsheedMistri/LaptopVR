import CoreVideo
import Foundation

/// The most recent decoded frame of every stream. Decoders write, the renderer reads.
final class FrameStore: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let frameID: UInt32
        /// When decoding finished, on the `CACurrentMediaTime()` clock.
        let decodedAt: CFTimeInterval
    }

    private let lock = NSLock()
    private var frames: [UInt16: Frame] = [:]

    func store(_ frame: Frame, stream: UInt16) {
        lock.withLock { frames[stream] = frame }
    }

    func latest() -> [UInt16: Frame] {
        lock.withLock { frames }
    }

    /// Forgets frames of streams that are no longer part of the scene.
    func keepOnly(_ streams: Set<UInt16>) {
        lock.withLock { frames = frames.filter { streams.contains($0.key) } }
    }
}
