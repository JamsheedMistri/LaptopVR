import Foundation
import Network
import VRProtocol

/// Accepts incoming links and advertises the service over Bonjour. The phone runs one of these;
/// USB tunnels and Wi-Fi connections both arrive here.
public final class LinkListener: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case listening
        case failed(String)
    }

    private let serviceName: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "laptopvr.listener")
    // Touched only on `queue`.
    private var listener: NWListener?
    /// A stopped listener holds the port until it reports that it has closed.
    private var closing: NWListener?
    private var running = false
    private var onState: (@Sendable (State) -> Void)?
    private var onLink: (@Sendable (Link) -> Void)?

    public init(serviceName: String, port: UInt16 = LaptopVRProtocol.port) {
        self.serviceName = serviceName
        self.port = port
    }

    public func start(onState: @escaping @Sendable (State) -> Void, onLink: @escaping @Sendable (Link) -> Void) {
        queue.async {
            self.onState = onState
            self.onLink = onLink
            self.running = true
            self.open()
        }
    }

    /// Starting again afterwards is safe at any time: the port is reopened once it is free.
    public func stop() {
        queue.async {
            self.running = false
            if let listener = self.listener {
                self.listener = nil
                self.closing = listener
                listener.cancel()
            }
            self.onState?(.stopped)
        }
    }

    private func open() {
        guard running, listener == nil, closing == nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: .laptopVR, on: port)
            listener.service = NWListener.Service(name: serviceName, type: LaptopVRProtocol.bonjourServiceType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.handle(state, of: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                let link = Link(channel: NetworkChannel(connection: connection), name: "\(connection.endpoint)")
                self?.onLink?(link)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onState?(.failed(error.localizedDescription))
            retry()
        }
    }

    private func handle(_ state: NWListener.State, of source: NWListener) {
        switch state {
        case .ready where source === listener:
            onState?(.listening)
        case .failed(let error) where source === listener:
            onState?(.failed(error.localizedDescription))
            source.cancel()
            listener = nil
            retry()
        case .cancelled where source === closing:
            closing = nil
            open()
        default:
            break
        }
    }

    private func retry() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.open()
        }
    }
}

/// Finds phones advertising the LaptopVR service on the local network.
public final class ServiceBrowser: @unchecked Sendable {
    public struct Service: Sendable, Hashable, Identifiable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }

    private let queue = DispatchQueue(label: "laptopvr.browser")
    // Touched only on `queue`.
    private var browser: NWBrowser?

    public init() {}

    public func start(onChange: @escaping @Sendable ([Service]) -> Void) {
        queue.async {
            let descriptor = NWBrowser.Descriptor.bonjour(type: LaptopVRProtocol.bonjourServiceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .laptopVR)
            browser.browseResultsChangedHandler = { results, _ in
                let services = results.compactMap { result -> Service? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Service(name: name, endpoint: result.endpoint)
                }
                onChange(services.sorted { $0.name < $1.name })
            }
            self.browser = browser
            browser.start(queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
        }
    }
}
