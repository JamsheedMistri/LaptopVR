import Foundation
import QuartzCore
import VRProtocol
import VRTransport
import VRVideo

/// The phone's end of the connection: accepts links from the Mac, decodes the video that
/// arrives, and passes everything else on as events.
///
/// The Mac may open several links (a cable tunnel and Wi-Fi). The phone greets each one, and
/// the one the Mac answers on becomes the live link.
final class HostConnection: @unchecked Sendable {
    enum Event: Sendable {
        /// The listener's state: nil when accepting connections, otherwise what went wrong.
        case listening(error: String?)
        case connected(HostHello)
        case disconnected
        case scene(SceneState)
        case command(HostCommand)
        case stats(HostStats)
        case asset(AssetMessage)
    }

    /// One stream's decoder and the queue it is confined to.
    private final class StreamDecoder: @unchecked Sendable {
        let queue = DispatchQueue(label: "laptopvr.decode", qos: .userInteractive)
        let decoder = VideoDecoder()
        var lastKeyframeRequest: CFTimeInterval = 0
    }

    private static let silenceTimeout: Duration = .seconds(5)

    private let frames: FrameStore
    private let listener: LinkListener
    private let queue = DispatchQueue(label: "laptopvr.host")

    // Touched only on `queue`.
    private var hello: ClientHello?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var candidates: [ObjectIdentifier: Link] = [:]
    /// The host on the live link. Only that host may replace the link with another.
    private var activeHostID: String?
    private var lastHeardAt = ContinuousClock.now
    private var timer: DispatchSourceTimer?

    // Read on link and decode queues, so guarded by a lock rather than the queue.
    private let lock = NSLock()
    private var activeLink: Link?
    private var decoders: [UInt16: StreamDecoder] = [:]
    private var decodeMillis = 0.0

    init(frames: FrameStore, deviceName: String) {
        self.frames = frames
        listener = LinkListener(serviceName: deviceName)
    }

    /// `hello` is what every Mac that connects is told about this phone.
    func start(hello: ClientHello, onEvent: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            self.hello = hello
            self.onEvent = onEvent
            listen()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkLiveness() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Closes the listener. iOS can take a suspended app's socket away, which would leave a
    /// listener that accepts nothing; closing it first means `resumeListening` opens a fresh one.
    func suspendListening() {
        queue.async { [self] in listener.stop() }
    }

    /// Opens the listener if it is not open already. Does nothing before `start`.
    func resumeListening() {
        queue.async { [self] in
            if hello != nil { listen() }
        }
    }

    /// Sends on the live link, if there is one. Safe to call from any thread.
    func send(_ frame: WireFrame) {
        lock.withLock { activeLink }?.send(frame)
    }

    /// Average time to decode a frame, in milliseconds.
    var averageDecodeMillis: Double {
        lock.withLock { decodeMillis }
    }

    // MARK: - Links

    private func listen() {
        listener.start(
            onState: { [weak self] state in
                guard let self else { return }
                queue.async {
                    switch state {
                    case .listening: self.onEvent?(.listening(error: nil))
                    case .failed(let message): self.onEvent?(.listening(error: message))
                    case .stopped: break
                    }
                }
            },
            onLink: { [weak self] link in
                guard let self else { return }
                queue.async { self.adopt(link) }
            }
        )
    }

    private func adopt(_ link: Link) {
        candidates[ObjectIdentifier(link)] = link
        link.start { [weak self, weak link] event in
            guard let self, let link else { return }
            // Video goes straight to its decoder without waiting behind other messages.
            if case .frame(let frame) = event, frame.type == .videoFrame {
                if self.lock.withLock({ self.activeLink === link }) {
                    self.decode(frame, from: link)
                }
                return
            }
            self.queue.async { self.handle(event, from: link) }
        }
    }

    private func handle(_ event: Link.Event, from link: Link) {
        let isActive = lock.withLock { activeLink === link }
        switch event {
        case .ready:
            guard var hello else { return }
            hello.connectedHostID = activeHostID
            link.send(.json(.hello, hello))

        case .frame(let frame):
            if isActive {
                lastHeardAt = .now
            }
            switch frame.type {
            case .hello:
                guard candidates[ObjectIdentifier(link)] != nil, let host = frame.decodeJSON(HostHello.self) else { return }
                if let activeHostID, activeHostID != host.hostID {
                    // Two Macs taking the phone from each other would never settle. The one
                    // that has it keeps it.
                    link.close()
                    return
                }
                promote(link, host: host)
            case .ping:
                link.send(frame.pong())
            case .scene where isActive:
                if let scene = frame.decodeJSON(SceneState.self) { onEvent?(.scene(scene)) }
            case .command where isActive:
                if let command = frame.decodeJSON(HostCommand.self) { onEvent?(.command(command)) }
            case .stats where isActive:
                if let stats = frame.decodeJSON(HostStats.self) { onEvent?(.stats(stats)) }
            case .asset where isActive:
                if let asset = try? AssetMessage(frame: frame) { onEvent?(.asset(asset)) }
            default:
                break
            }

        case .closed:
            candidates[ObjectIdentifier(link)] = nil
            if isActive {
                lock.withLock {
                    activeLink = nil
                    decoders = [:]
                }
                activeHostID = nil
                onEvent?(.disconnected)
            }
        }
    }

    /// The Mac answered on this link, so it is the one to use from now on.
    private func promote(_ link: Link, host: HostHello) {
        candidates[ObjectIdentifier(link)] = nil
        let previous = lock.withLock { () -> Link? in
            defer {
                activeLink = link
                // The new link's video starts with a keyframe; old decoders are of no use.
                decoders = [:]
            }
            return activeLink
        }
        activeHostID = host.hostID
        lastHeardAt = .now
        // Closed after the swap, so its closing is not taken for a disconnection.
        previous?.close()
        onEvent?(.connected(host))
    }

    private func checkLiveness() {
        // The Mac pings every second; silence means the link is dead even if it has not closed.
        if ContinuousClock.now - lastHeardAt > Self.silenceTimeout {
            lock.withLock { activeLink }?.close()
        }
    }

    // MARK: - Video

    private func decode(_ frame: WireFrame, from link: Link) {
        guard let packet = try? VideoPacket(frame: frame) else { return }
        let stream = lock.withLock { () -> StreamDecoder in
            if let existing = decoders[packet.stream] { return existing }
            let created = StreamDecoder()
            decoders[packet.stream] = created
            return created
        }

        stream.queue.async { [frames, weak self] in
            let started = CACurrentMediaTime()
            let outcome = stream.decoder.decode(packet)
            let finished = CACurrentMediaTime()

            switch outcome {
            case .frame(let pixelBuffer):
                frames.store(
                    FrameStore.Frame(pixelBuffer: pixelBuffer, frameID: packet.frameID, decodedAt: finished),
                    stream: packet.stream
                )
            case .needsKeyframe:
                // Every frame fails until the keyframe arrives; one request is enough.
                if finished - stream.lastKeyframeRequest > 0.25 {
                    stream.lastKeyframeRequest = finished
                    link.send(.keyframeRequest(stream: packet.stream))
                }
            }

            // Acknowledge failures too: the Mac limits how many frames are unacknowledged.
            link.send(VideoAck(
                stream: packet.stream,
                frameID: packet.frameID,
                captureTimeNanos: packet.captureTimeNanos,
                decodeMicros: UInt32(clamping: Int((finished - started) * 1_000_000))
            ).frame())

            guard let self else { return }
            let millis = (finished - started) * 1000
            self.lock.withLock {
                self.decodeMillis = self.decodeMillis == 0 ? millis : self.decodeMillis * 0.9 + millis * 0.1
            }
        }
    }
}
