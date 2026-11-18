#if os(macOS)
import Foundation

/// A byte channel over an already-connected socket. Used for usbmux tunnels, which hand back a
/// raw file descriptor once the tunnel is established.
public final class FileDescriptorChannel: ByteChannel, @unchecked Sendable {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var startedQueue: DispatchQueue?
    private var closedBeforeStart = false
    // Touched only on the queue passed to `start`.
    private var io: DispatchIO?
    private var handler: (@Sendable (ByteChannelEvent) -> Void)?
    private var finished = false

    /// Takes ownership of `fileDescriptor` and closes it when the channel ends.
    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        // A channel that was never started still holds the descriptor it was given. Once
        // started, the DispatchIO owns it, and the block below keeps the channel alive till then.
        if startedQueue == nil, !closedBeforeStart {
            close(fileDescriptor)
        }
    }

    public func start(queue: DispatchQueue, handler: @escaping @Sendable (ByteChannelEvent) -> Void) {
        let canStart = lock.withLock { () -> Bool in
            guard startedQueue == nil, !closedBeforeStart else { return false }
            startedQueue = queue
            return true
        }
        guard canStart else { return }
        queue.async { [self] in
            self.handler = handler
            let descriptor = self.fileDescriptor
            let io = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
                close(descriptor)
            }
            // Deliver bytes as soon as they arrive instead of waiting for a full buffer.
            io.setLimit(lowWater: 1)
            self.io = io
            handler(.ready)

            io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, chunk, error in
                guard let self, !self.finished else { return }
                if let chunk, !chunk.isEmpty {
                    var bytes = Data(capacity: chunk.count)
                    chunk.enumerateBytes { buffer, _, _ in bytes.append(buffer) }
                    self.handler?(.data(bytes))
                }
                if error != 0 {
                    self.finish(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                } else if done {
                    self.finish(nil)
                }
            }
        }
    }

    public func send(_ data: Data) {
        guard let queue = lock.withLock({ startedQueue }) else { return }
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        queue.async { [weak self] in
            guard let self, let io = self.io, !self.finished else { return }
            io.write(offset: 0, data: payload, queue: queue) { [weak self] _, _, error in
                if error != 0 {
                    self?.finish(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                }
            }
        }
    }

    public func cancel() {
        let queue = lock.withLock { () -> DispatchQueue? in
            if startedQueue == nil, !closedBeforeStart {
                closedBeforeStart = true
                close(fileDescriptor)
            }
            return startedQueue
        }
        guard let queue else { return }
        // Captured strongly: the descriptor is only released by `finish`, so it must run even if
        // the owner lets go of the channel right after cancelling.
        queue.async {
            self.finish(nil)
        }
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        io?.close(flags: .stop)
        io = nil
        handler?(.closed(error))
        handler = nil
    }
}
#endif
