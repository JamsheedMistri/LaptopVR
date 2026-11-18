import Foundation
import Network

public enum ByteChannelEvent: Sendable {
    case ready
    case data(Data)
    /// Delivered exactly once, after which no further events arrive.
    case closed((any Error)?)
}

/// A reliable, ordered byte stream. Wi-Fi uses `NetworkChannel`; USB uses `FileDescriptorChannel`
/// over a usbmux tunnel. `Link` layers message framing on top of either.
public protocol ByteChannel: AnyObject, Sendable {
    /// Starts the channel. Events are delivered on `queue`.
    func start(queue: DispatchQueue, handler: @escaping @Sendable (ByteChannelEvent) -> Void)
    func send(_ data: Data)
    func cancel()
}

extension NWParameters {
    /// TCP tuned for interactive video: no Nagle delay, fast dead-peer detection, and the
    /// video Wi-Fi access category. Peer-to-peer (AWDL) stays off because its channel hopping
    /// causes periodic latency spikes.
    public static var laptopVR: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 4

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// A byte channel backed by a Network.framework connection.
public final class NetworkChannel: ByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    // Touched only on the queue passed to `start`.
    private var handler: (@Sendable (ByteChannelEvent) -> Void)?
    private var finished = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .laptopVR))
    }

    public func start(queue: DispatchQueue, handler: @escaping @Sendable (ByteChannelEvent) -> Void) {
        queue.async { [self] in
            self.handler = handler
            self.connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            self.connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    public func cancel() {
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            handler?(.ready)
            receive()
        case .waiting(let error), .failed(let error):
            // A waiting connection has no usable path yet; fail so the caller can retry.
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.handler?(.data(data))
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        handler?(.closed(error))
        handler = nil
    }
}
