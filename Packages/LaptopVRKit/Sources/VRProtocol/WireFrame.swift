import Foundation

public enum LaptopVRProtocol {
    public static let version = 1
    /// TCP port the phone listens on. usbmux tunnels need a fixed, known port.
    public static let port: UInt16 = 27183
    public static let bonjourServiceType = "_laptopvr._tcp"
    /// Most screens a scene can contain. Mirrors the texture slots in the phone's shader.
    public static let maxScreens = 6
}

public enum MessageType: UInt8, Sendable {
    // Control, JSON payloads.
    case hello = 1
    case scene = 2
    case command = 3
    case status = 4
    case stats = 5
    // Binary payloads.
    case asset = 8
    case videoFrame = 16
    case videoAck = 17
    case keyframeRequest = 18
    case ping = 32
    case pong = 33
}

/// One message on the wire: an 8-byte header followed by the payload.
///
///     type: u8 | flags: u8 | stream: u16 | payloadLength: u32   (little-endian)
public struct WireFrame: Sendable {
    public static let headerSize = 8
    public static let maxPayloadSize = 32 << 20

    public var type: MessageType
    public var flags: UInt8
    public var stream: UInt16
    public var payload: Data

    public init(type: MessageType, flags: UInt8 = 0, stream: UInt16 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.stream = stream
        self.payload = payload
    }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: Self.headerSize + payload.count)
        writer.write(type.rawValue)
        writer.write(flags)
        writer.write(stream)
        writer.write(UInt32(payload.count))
        writer.write(payload)
        return writer.data
    }
}

/// Incrementally splits a byte stream into frames. Frames of unknown type are skipped so newer
/// peers can add messages without breaking older ones.
public struct FrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [WireFrame] {
        buffer.append(bytes)
        var frames: [WireFrame] = []
        var consumed = 0

        while buffer.count - consumed >= WireFrame.headerSize {
            let headerStart = buffer.startIndex + consumed
            var header = ByteReader(buffer.subdata(in: headerStart..<(headerStart + WireFrame.headerSize)))
            let rawType: UInt8 = try header.read()
            let flags: UInt8 = try header.read()
            let stream: UInt16 = try header.read()
            let length = Int(try header.read(UInt32.self))
            guard length <= WireFrame.maxPayloadSize else { throw WireError.payloadTooLarge(length) }

            let total = WireFrame.headerSize + length
            guard buffer.count - consumed >= total else { break }

            if let type = MessageType(rawValue: rawType) {
                let payloadStart = headerStart + WireFrame.headerSize
                let payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
                frames.append(WireFrame(type: type, flags: flags, stream: stream, payload: payload))
            }
            consumed += total
        }

        if consumed > 0 {
            buffer = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
        }
        return frames
    }
}

// MARK: - JSON control messages

extension WireFrame {
    public static func json<T: Encodable>(_ type: MessageType, _ value: T) -> WireFrame {
        // Encoding our own plain Codable structs cannot fail.
        let payload = (try? JSONEncoder().encode(value)) ?? Data()
        return WireFrame(type: type, payload: payload)
    }

    public func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }
}
