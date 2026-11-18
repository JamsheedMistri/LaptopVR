#if os(macOS)
import Foundation

/// An iPhone attached by cable, as reported by the system USB multiplexer.
public struct UsbmuxDevice: Sendable, Hashable {
    public let id: Int
    public let serialNumber: String
}

public enum UsbmuxError: Error, Sendable {
    case daemonUnavailable
    case protocolViolation
    /// The daemon's result code. 3 means nothing is listening on the device port.
    case refused(Int)
}

/// Minimal client for `usbmuxd`, the macOS daemon that tunnels TCP connections to an attached
/// iPhone over the USB cable. Replaces the vendored PeerTalk library.
public enum Usbmux {
    /// Opens a tunnel to `port` on the device. Blocks briefly; call off the main thread.
    public static func openTunnel(to device: UsbmuxDevice, port: UInt16) throws -> FileDescriptorChannel {
        let socket = try UsbmuxSocket()
        do {
            try socket.setReceiveTimeout(seconds: 3)
            try socket.send([
                "MessageType": "Connect",
                "DeviceID": device.id,
                // usbmuxd expects the port in network byte order.
                "PortNumber": Int(port.bigEndian),
            ])
            let reply = try socket.receive()
            guard let code = reply["Number"] as? Int else { throw UsbmuxError.protocolViolation }
            guard code == 0 else { throw UsbmuxError.refused(code) }
            try socket.setReceiveTimeout(seconds: 0)
        } catch {
            socket.close()
            throw error
        }
        // From here on the socket is a raw byte pipe to the phone.
        return FileDescriptorChannel(fileDescriptor: socket.fileDescriptor)
    }
}

/// Watches for iPhones being plugged in and unplugged.
public final class UsbmuxMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: UsbmuxSocket?
    private var stopped = true

    public init() {}

    public func start(onChange: @escaping @Sendable ([UsbmuxDevice]) -> Void) {
        lock.withLock { stopped = false }
        let thread = Thread { [weak self] in
            self?.run(onChange: onChange)
        }
        thread.name = "laptopvr.usbmux"
        thread.start()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            socket?.close()
            socket = nil
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func run(onChange: @Sendable ([UsbmuxDevice]) -> Void) {
        while !isStopped {
            do {
                try listen(onChange: onChange)
            } catch {
                onChange([])
            }
            // The daemon went away or was not there; try again shortly.
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func listen(onChange: @Sendable ([UsbmuxDevice]) -> Void) throws {
        let socket = try UsbmuxSocket()
        lock.withLock { self.socket = socket }
        defer {
            lock.withLock { self.socket = nil }
            socket.close()
        }

        try socket.send(["MessageType": "Listen"])
        var devices: [Int: UsbmuxDevice] = [:]

        while !isStopped {
            let message = try socket.receive()
            guard let type = message["MessageType"] as? String, let id = message["DeviceID"] as? Int else {
                continue
            }
            switch type {
            case "Attached":
                let properties = message["Properties"] as? [String: Any] ?? [:]
                // The daemon also reports phones reachable over Wi-Fi sync; only cables count here.
                guard properties["ConnectionType"] as? String == "USB" else { continue }
                devices[id] = UsbmuxDevice(id: id, serialNumber: properties["SerialNumber"] as? String ?? "")
            case "Detached":
                devices[id] = nil
            default:
                continue
            }
            onChange(devices.values.sorted { $0.id < $1.id })
        }
    }
}

/// A blocking connection to the usbmuxd control socket, speaking its plist protocol.
private final class UsbmuxSocket: @unchecked Sendable {
    private static let path = "/var/run/usbmuxd"
    private static let headerSize = 16
    private static let plistProtocolVersion: UInt32 = 1
    private static let plistMessageType: UInt32 = 8

    let fileDescriptor: Int32
    private var tag: UInt32 = 0
    private let closeLock = NSLock()
    private var closed = false

    init() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UsbmuxError.daemonUnavailable }

        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            Self.path.utf8CString.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count - 1)))
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw UsbmuxError.daemonUnavailable
        }
        fileDescriptor = descriptor
    }

    func close() {
        closeLock.withLock {
            guard !closed else { return }
            closed = true
            // Shutting down first wakes a thread blocked in read().
            shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
    }

    func setReceiveTimeout(seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw UsbmuxError.protocolViolation
        }
    }

    func send(_ message: [String: Any]) throws {
        var message = message
        message["ProgName"] = "LaptopVR"
        message["ClientVersionString"] = "LaptopVR"
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)

        tag += 1
        var packet = Data(capacity: Self.headerSize + body.count)
        for field in [UInt32(Self.headerSize + body.count), Self.plistProtocolVersion, Self.plistMessageType, tag] {
            withUnsafeBytes(of: field.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        try writeAll(packet)
    }

    func receive() throws -> [String: Any] {
        let header = try readExactly(Self.headerSize)
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length >= Self.headerSize, length < 1 << 20 else { throw UsbmuxError.protocolViolation }
        let body = try readExactly(length - Self.headerSize)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw UsbmuxError.protocolViolation
        }
        return plist
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fileDescriptor, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 {
                offset += written
            } else if errno != EINTR {
                throw UsbmuxError.daemonUnavailable
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress! + offset, count - offset) }
            if received > 0 {
                offset += received
            } else if received == 0 || errno != EINTR {
                throw UsbmuxError.daemonUnavailable
            }
        }
        return data
    }
}
#endif
