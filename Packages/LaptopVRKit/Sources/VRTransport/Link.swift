import Foundation
import VRProtocol

/// A framed, bidirectional message connection between the Mac and the phone.
public final class Link: @unchecked Sendable {
    public enum Event: Sendable {
        case ready
        case frame(WireFrame)
        /// Delivered exactly once.
        case closed((any Error)?)
    }

    /// Human-readable description of the peer, for logs and UI.
    public let name: String

    private let channel: any ByteChannel
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var parser = FrameParser()
    private var handler: (@Sendable (Event) -> Void)?

    public init(channel: any ByteChannel, name: String) {
        self.channel = channel
        self.name = name
        queue = DispatchQueue(label: "laptopvr.link", qos: .userInteractive)
    }

    /// Starts the link. Events are delivered on the link's private serial queue.
    public func start(handler: @escaping @Sendable (Event) -> Void) {
        queue.async {
            self.handler = handler
        }
        channel.start(queue: queue) { [weak self] event in
            self?.handle(event)
        }
    }

    public func send(_ frame: WireFrame) {
        channel.send(frame.encoded())
    }

    public func close() {
        channel.cancel()
    }

    private func handle(_ event: ByteChannelEvent) {
        switch event {
        case .ready:
            handler?(.ready)
        case .data(let data):
            do {
                for frame in try parser.append(data) {
                    handler?(.frame(frame))
                }
            } catch {
                // A corrupt stream cannot be resynchronised; drop the connection.
                channel.cancel()
            }
        case .closed(let error):
            handler?(.closed(error))
            handler = nil
        }
    }
}
