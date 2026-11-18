import Foundation
import VRProtocol

/// The set of display streams of a running session, one per screen shown in the headset.
final class StreamSession: @unchecked Sendable {
    private let send: @Sendable (WireFrame) -> Void
    private let lock = NSLock()
    private var streams: [UInt16: DisplayStream] = [:]

    struct Failure: Sendable {
        let streamID: UInt16
        let message: String
    }

    /// Streams that stopped by themselves, for example because their display was unplugged.
    let failures: AsyncStream<Failure>
    private let failureContinuation: AsyncStream<Failure>.Continuation

    init(send: @escaping @Sendable (WireFrame) -> Void) {
        self.send = send
        (failures, failureContinuation) = AsyncStream.makeStream()
    }

    /// Starts, updates, and stops streams so they match `configurations`. Calls must not overlap.
    func apply(_ configurations: [StreamConfiguration]) async throws {
        let existing = lock.withLock { streams }
        let wanted = Dictionary(configurations.map { ($0.streamID, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, stream) in existing {
            // A stream cannot move to another display; replace it instead.
            if wanted[id]?.displayID != stream.currentConfiguration.displayID {
                await stream.stop()
                lock.withLock { streams[id] = nil }
            }
        }

        for configuration in configurations {
            if let stream = lock.withLock({ streams[configuration.streamID] }) {
                try await stream.update(to: configuration)
            } else {
                let stream = DisplayStream(configuration: configuration, send: send) { [failureContinuation] id, message in
                    failureContinuation.yield(Failure(streamID: id, message: message))
                }
                try await stream.start()
                lock.withLock { streams[configuration.streamID] = stream }
            }
        }
    }

    /// Stops the given streams. Do this before removing their displays, because a stream whose
    /// display disappears reports a failure.
    func stop(_ streamIDs: [UInt16]) async {
        for id in streamIDs {
            let stream = lock.withLock { streams.removeValue(forKey: id) }
            await stream?.stop()
        }
    }

    func stopAll() async {
        let all = lock.withLock { () -> [DisplayStream] in
            defer { streams = [:] }
            return Array(streams.values)
        }
        for stream in all {
            await stream.stop()
        }
    }

    /// Routes acknowledgements and keyframe requests. Called on the link's queue.
    func handle(_ frame: WireFrame) {
        guard let stream = lock.withLock({ streams[frame.stream] }) else { return }
        switch frame.type {
        case .videoAck:
            if let ack = try? VideoAck(frame: frame) {
                stream.handle(ack)
            }
        case .keyframeRequest:
            stream.requestKeyframe()
        default:
            break
        }
    }

    func resetForNewLink() {
        lock.withLock { Array(streams.values) }.forEach { $0.resetForNewLink() }
    }

    func takeStats() -> [StreamStats] {
        lock.withLock { Array(streams.values) }
            .map { $0.takeStats() }
            .sorted { $0.stream < $1.stream }
    }
}
