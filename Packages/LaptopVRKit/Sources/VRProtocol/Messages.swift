import Foundation

// MARK: - Handshake

/// Sent by the phone as soon as a link opens.
public struct ClientHello: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    public var supportsHEVC: Bool
    public var maxFramesPerSecond: Int
    /// The host the phone is already in use by, if any. Another host should leave it alone.
    public var connectedHostID: String?

    public init(protocolVersion: Int = LaptopVRProtocol.version, deviceName: String, supportsHEVC: Bool, maxFramesPerSecond: Int, connectedHostID: String? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.supportsHEVC = supportsHEVC
        self.maxFramesPerSecond = maxFramesPerSecond
        self.connectedHostID = connectedHostID
    }
}

/// Sent by the Mac in reply to `ClientHello`.
public struct HostHello: Codable, Sendable {
    public var protocolVersion: Int
    /// Identifies this run of the Mac app, so the phone can tell a second link from the same
    /// host (which replaces the first) from another host (which must not).
    public var hostID: String
    public var hostName: String
    /// "usb" or "wifi", as seen from the Mac.
    public var transport: String

    public init(protocolVersion: Int = LaptopVRProtocol.version, hostID: String, hostName: String, transport: String) {
        self.protocolVersion = protocolVersion
        self.hostID = hostID
        self.hostName = hostName
        self.transport = transport
    }
}

// MARK: - Mac to phone

/// One-shot events, as opposed to the persistent `SceneState`.
public enum HostCommand: Codable, Sendable {
    case recenter
    case toast(String)
}

public struct StreamStats: Codable, Sendable {
    public var stream: UInt16
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    public var megabitsPerSecond: Double
    public var encodeMillis: Double
    /// Capture to decoded-on-phone, measured on the Mac from acknowledgements.
    public var pipelineMillis: Double
    public var droppedFrames: Int

    public init(stream: UInt16, width: Int, height: Int, framesPerSecond: Double, megabitsPerSecond: Double, encodeMillis: Double, pipelineMillis: Double, droppedFrames: Int) {
        self.stream = stream
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.megabitsPerSecond = megabitsPerSecond
        self.encodeMillis = encodeMillis
        self.pipelineMillis = pipelineMillis
        self.droppedFrames = droppedFrames
    }
}

public struct HostStats: Codable, Sendable {
    public var codec: String
    public var transport: String
    public var streams: [StreamStats]

    public init(codec: String, transport: String, streams: [StreamStats]) {
        self.codec = codec
        self.transport = transport
        self.streams = streams
    }
}

// MARK: - Phone to Mac

public struct ClientStatus: Codable, Sendable, Equatable {
    /// 0...1, or nil when unknown.
    public var batteryLevel: Double?
    public var isCharging: Bool
    /// 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalState: Int
    public var headsetActive: Bool
    /// True when ARKit supplies position as well as rotation.
    public var positionalTracking: Bool
    /// Resolution of the viewer at the lens centre. The Mac uses it to pick a stream size.
    public var pixelsPerDegree: Double
    public var renderFramesPerSecond: Double
    public var decodeMillis: Double
    /// Decoded to on-glass, measured on the phone.
    public var presentMillis: Double

    public init(batteryLevel: Double?, isCharging: Bool, thermalState: Int, headsetActive: Bool, positionalTracking: Bool, pixelsPerDegree: Double, renderFramesPerSecond: Double, decodeMillis: Double, presentMillis: Double) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.thermalState = thermalState
        self.headsetActive = headsetActive
        self.positionalTracking = positionalTracking
        self.pixelsPerDegree = pixelsPerDegree
        self.renderFramesPerSecond = renderFramesPerSecond
        self.decodeMillis = decodeMillis
        self.presentMillis = presentMillis
    }
}

// MARK: - Binary messages

public enum VideoCodec: UInt8, Codable, Sendable, CaseIterable {
    case h264 = 1
    case hevc = 2

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// One encoded frame. `data` holds length-prefixed (AVCC) NAL units exactly as VideoToolbox
/// produced them; parameter sets travel with keyframes only.
public struct VideoPacket: Sendable {
    public var stream: UInt16
    public var frameID: UInt32
    /// Capture time on the Mac's host clock. Echoed back in the acknowledgement.
    public var captureTimeNanos: UInt64
    public var encodeMicros: UInt32
    public var codec: VideoCodec
    public var isKeyframe: Bool
    public var width: UInt16
    public var height: UInt16
    public var parameterSets: [Data]
    public var data: Data

    public init(stream: UInt16, frameID: UInt32, captureTimeNanos: UInt64, encodeMicros: UInt32, codec: VideoCodec, isKeyframe: Bool, width: UInt16, height: UInt16, parameterSets: [Data], data: Data) {
        self.stream = stream
        self.frameID = frameID
        self.captureTimeNanos = captureTimeNanos
        self.encodeMicros = encodeMicros
        self.codec = codec
        self.isKeyframe = isKeyframe
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.data = data
    }

    private static let keyframeFlag: UInt8 = 1

    public func frame() -> WireFrame {
        var writer = ByteWriter(capacity: 32 + data.count)
        writer.write(frameID)
        writer.write(captureTimeNanos)
        writer.write(encodeMicros)
        writer.write(codec.rawValue)
        writer.write(UInt8(clamping: parameterSets.count))
        writer.write(width)
        writer.write(height)
        for set in parameterSets.prefix(Int(UInt8.max)) {
            writer.writeLengthPrefixed(set)
        }
        writer.write(data)
        return WireFrame(type: .videoFrame, flags: isKeyframe ? Self.keyframeFlag : 0, stream: stream, payload: writer.data)
    }

    public init(frame: WireFrame) throws {
        var reader = ByteReader(frame.payload)
        stream = frame.stream
        isKeyframe = frame.flags & Self.keyframeFlag != 0
        frameID = try reader.read()
        captureTimeNanos = try reader.read()
        encodeMicros = try reader.read()
        guard let codec = VideoCodec(rawValue: try reader.read()) else {
            throw WireError.malformed("unknown codec")
        }
        self.codec = codec
        let setCount = Int(try reader.read(UInt8.self))
        width = try reader.read()
        height = try reader.read()
        parameterSets = try (0..<setCount).map { _ in try reader.readLengthPrefixed() }
        data = reader.readRemaining()
    }
}

/// Sent by the phone once a frame has been decoded. Bounds how many frames are in flight.
public struct VideoAck: Sendable {
    public var stream: UInt16
    public var frameID: UInt32
    public var captureTimeNanos: UInt64
    public var decodeMicros: UInt32

    public init(stream: UInt16, frameID: UInt32, captureTimeNanos: UInt64, decodeMicros: UInt32) {
        self.stream = stream
        self.frameID = frameID
        self.captureTimeNanos = captureTimeNanos
        self.decodeMicros = decodeMicros
    }

    public func frame() -> WireFrame {
        var writer = ByteWriter(capacity: 16)
        writer.write(frameID)
        writer.write(captureTimeNanos)
        writer.write(decodeMicros)
        return WireFrame(type: .videoAck, stream: stream, payload: writer.data)
    }

    public init(frame: WireFrame) throws {
        var reader = ByteReader(frame.payload)
        stream = frame.stream
        frameID = try reader.read()
        captureTimeNanos = try reader.read()
        decodeMicros = try reader.read()
    }
}

/// A named blob, used for the environment background image.
public struct AssetMessage: Sendable {
    public var id: String
    public var data: Data

    public init(id: String, data: Data) {
        self.id = id
        self.data = data
    }

    public func frame() -> WireFrame {
        var writer = ByteWriter(capacity: 8 + data.count)
        writer.writeLengthPrefixed(Data(id.utf8))
        writer.write(data)
        return WireFrame(type: .asset, payload: writer.data)
    }

    public init(frame: WireFrame) throws {
        var reader = ByteReader(frame.payload)
        id = String(decoding: try reader.readLengthPrefixed(), as: UTF8.self)
        data = reader.readRemaining()
    }
}

extension WireFrame {
    public static func keyframeRequest(stream: UInt16) -> WireFrame {
        WireFrame(type: .keyframeRequest, stream: stream)
    }

    /// Ping and pong carry an opaque 64-bit value that the peer echoes back.
    public static func ping(_ value: UInt64) -> WireFrame {
        var writer = ByteWriter(capacity: 8)
        writer.write(value)
        return WireFrame(type: .ping, payload: writer.data)
    }

    public func pong() -> WireFrame {
        WireFrame(type: .pong, payload: payload)
    }

    public var pingValue: UInt64? {
        var reader = ByteReader(payload)
        return try? reader.read(UInt64.self)
    }
}
