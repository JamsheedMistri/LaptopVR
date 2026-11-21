import Foundation
import VRProtocol
import VRTransport

enum Transport: String, Sendable {
    case usb, wifi

    var title: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        }
    }
}

/// The connected phone.
struct Peer: Sendable, Equatable {
    var name: String
    var transport: Transport
    var supportsHEVC: Bool
    var maxFramesPerSecond: Int
}

/// Finds the phone and keeps one link to it open, preferring the cable.
///
/// The phone listens; the Mac dials, either through a usbmux tunnel or to the Bonjour service on
/// Wi-Fi. The phone says hello on every link it accepts, and the Mac answers only on the link it
/// decides to use, so both sides agree which one is live. When a cable is plugged in during a
/// Wi-Fi session the new link is promoted before the old one is closed.
final class HostEndpoint: @unchecked Sendable {
    enum Event: Sendable {
        /// Also sent when the link is replaced by one on a better transport.
        case connected(Peer)
        case disconnected
        case status(ClientStatus)
    }

    private final class Connection: @unchecked Sendable {
        let link: Link
        let transport: Transport
        let openedAt = ContinuousClock.now
        var lastHeardAt = ContinuousClock.now

        init(link: Link, transport: Transport) {
            self.link = link
            self.transport = transport
        }
    }

    private static let helloTimeout: Duration = .seconds(3)
    private static let silenceTimeout: Duration = .seconds(5)
    /// Least time between two attempts on one transport. A link that closes is redialled at
    /// once, so without this a phone that keeps hanging up would be dialled without pause.
    private static let redialInterval: Duration = .milliseconds(800)

    private let queue = DispatchQueue(label: "laptopvr.endpoint")
    private let usbMonitor = UsbmuxMonitor()
    private let browser = ServiceBrowser()
    private let hostName: String
    /// Names this run of the app to the phone.
    private let hostID = UUID().uuidString

    // Touched only on `queue`.
    private var preference: ConnectionPreference = .automatic
    private var onEvent: (@Sendable (Event) -> Void)?
    private var usbDevices: [UsbmuxDevice] = []
    private var services: [ServiceBrowser.Service] = []
    private var active: Connection?
    private var pending: [Transport: Connection] = [:]
    private var usbAttemptInProgress = false
    private var usbFailures = 0
    private var lastDialAt: [Transport: ContinuousClock.Instant] = [:]
    private var timer: DispatchSourceTimer?

    // Read from capture and encoder threads, so guarded by a lock rather than the queue.
    private let lock = NSLock()
    private var activeLink: Link?
    private var videoHandler: (@Sendable (WireFrame) -> Void)?

    init(hostName: String) {
        self.hostName = hostName
    }

    func start(preference: ConnectionPreference, onEvent: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            self.preference = preference
            self.onEvent = onEvent

            usbMonitor.start { [weak self] devices in
                guard let self else { return }
                queue.async {
                    self.usbDevices = devices
                    self.usbFailures = 0
                    self.evaluate()
                }
            }
            browser.start { [weak self] services in
                guard let self else { return }
                queue.async {
                    self.services = services
                    self.evaluate()
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func setPreference(_ preference: ConnectionPreference) {
        queue.async { [self] in
            self.preference = preference
            evaluate()
        }
    }

    /// Sends on the live link, if there is one. Safe to call from any thread.
    func send(_ frame: WireFrame) {
        lock.withLock { activeLink }?.send(frame)
    }

    /// Receives video acknowledgements, keyframe requests, the phone's view, and its camera's
    /// picture directly on the link's queue, bypassing the main thread.
    func setVideoHandler(_ handler: (@Sendable (WireFrame) -> Void)?) {
        lock.withLock { videoHandler = handler }
    }

    // MARK: - Connecting

    private func allows(_ transport: Transport) -> Bool {
        transport == .usb ? preference.allowsUSB : preference.allowsWiFi
    }

    private func evaluate() {
        if let active, !allows(active.transport) {
            active.link.close()
        }

        let canUseUSB = preference.allowsUSB && !usbDevices.isEmpty
        if canUseUSB, active?.transport != .usb, pending[.usb] == nil, !usbAttemptInProgress, mayDial(.usb) {
            attemptUSB()
        }

        // An attached phone that keeps refusing is probably a different device, or the app is
        // closed; fall back to Wi-Fi after a couple of failures.
        let usbLooksHopeless = !canUseUSB || usbFailures >= 2
        if preference.allowsWiFi, usbLooksHopeless, active == nil, pending[.wifi] == nil,
           let service = services.first, mayDial(.wifi) {
            lastDialAt[.wifi] = .now
            adopt(NetworkChannel(endpoint: service.endpoint), transport: .wifi, name: service.name)
        }
    }

    /// The once-a-second tick calls `evaluate` again, so an attempt held back here is not lost.
    private func mayDial(_ transport: Transport) -> Bool {
        guard let last = lastDialAt[transport] else { return true }
        return ContinuousClock.now - last >= Self.redialInterval
    }

    private func attemptUSB() {
        usbAttemptInProgress = true
        lastDialAt[.usb] = .now
        let devices = usbDevices
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A plain loop, not a lazy chain: every call opens a tunnel, so each device must be
            // tried exactly once and nothing opened may be dropped.
            var opened: FileDescriptorChannel?
            for device in devices where opened == nil {
                opened = try? Usbmux.openTunnel(to: device, port: LaptopVRProtocol.port)
            }
            let channel = opened
            guard let self else { return }
            queue.async {
                self.usbAttemptInProgress = false
                if let channel {
                    self.adopt(channel, transport: .usb, name: "USB")
                } else {
                    self.usbFailures += 1
                }
            }
        }
    }

    private func adopt(_ channel: any ByteChannel, transport: Transport, name: String) {
        let connection = Connection(link: Link(channel: channel, name: name), transport: transport)
        pending[transport] = connection
        connection.link.start { [weak self, weak connection] event in
            guard let self, let connection else { return }
            // Video feedback, the phone's view, and its camera's picture arrive at frame rate;
            // hand them over without leaving this queue.
            if case .frame(let frame) = event,
               [.videoAck, .keyframeRequest, .view, .camera].contains(frame.type) {
                self.lock.withLock { self.videoHandler }?(frame)
                return
            }
            self.queue.async {
                self.handle(event, from: connection)
            }
        }
    }

    // MARK: - Link events

    private func handle(_ event: Link.Event, from connection: Connection) {
        switch event {
        case .ready:
            break
        case .frame(let frame):
            connection.lastHeardAt = .now
            handle(frame, from: connection)
        case .closed:
            if active === connection {
                active = nil
                lock.withLock { activeLink = nil }
                onEvent?(.disconnected)
            }
            if pending[connection.transport] === connection {
                pending[connection.transport] = nil
                if connection.transport == .usb { usbFailures += 1 }
            }
            evaluate()
        }
    }

    private func handle(_ frame: WireFrame, from connection: Connection) {
        switch frame.type {
        case .hello:
            guard pending[connection.transport] === connection,
                  let hello = frame.decodeJSON(ClientHello.self)
            else { return }
            pending[connection.transport] = nil
            if let other = hello.connectedHostID, other != hostID {
                // Another Mac, or another copy of this app, has the phone. Leave it be; the
                // next attempt finds out whether it has been let go.
                connection.link.close()
                return
            }
            promote(connection, hello: hello)
        case .status:
            guard active === connection, let status = frame.decodeJSON(ClientStatus.self) else { return }
            onEvent?(.status(status))
        case .ping:
            connection.link.send(frame.pong())
        default:
            break
        }
    }

    private func promote(_ connection: Connection, hello: ClientHello) {
        // Keep an existing link unless the new one is the cable replacing Wi-Fi.
        if let active, !(active.transport == .wifi && connection.transport == .usb) {
            connection.link.close()
            return
        }

        let previous = active
        active = connection
        lock.withLock { activeLink = connection.link }
        usbFailures = 0
        // Closing after the swap means the old link's close is not mistaken for a disconnect.
        previous?.link.close()

        connection.link.send(.json(.hello, HostHello(
            hostID: hostID, hostName: hostName, transport: connection.transport.rawValue)))
        onEvent?(.connected(Peer(
            name: hello.deviceName,
            transport: connection.transport,
            supportsHEVC: hello.supportsHEVC,
            maxFramesPerSecond: hello.maxFramesPerSecond
        )))
    }

    // MARK: - Liveness

    private func tick() {
        let now = ContinuousClock.now
        if let active {
            if now - active.lastHeardAt > Self.silenceTimeout {
                active.link.close()
            } else {
                active.link.send(.ping(hostTimeNanos()))
            }
        }
        for connection in pending.values where now - connection.openedAt > Self.helloTimeout {
            connection.link.close()
        }
        evaluate()
    }
}
