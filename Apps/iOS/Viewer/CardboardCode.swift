import Foundation

/// Reads the viewer description out of a Google Cardboard QR code.
///
/// The code holds a URL whose `p` parameter is a base64url-encoded protocol buffer
/// (`DeviceParams`). Older codes hold a short link that redirects to such a URL.
enum CardboardCode {
    static func profile(from text: String) async -> ViewerProfile? {
        guard var components = URLComponents(string: text.contains("://") ? text : "https://" + text) else { return nil }
        if let profile = profile(in: components) {
            return profile
        }
        // The original viewer's code is a bare link with no parameters.
        if components.host == "g.co", components.path == "/cardboard" {
            return .cardboardV1
        }

        // Follow a short link just far enough to see where it points.
        components.scheme = "https"
        guard let url = components.url else { return nil }
        let catcher = RedirectCatcher()
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        _ = try? await URLSession.shared.data(for: request, delegate: catcher)
        return catcher.profile
    }

    fileprivate static func profile(in components: URLComponents) -> ViewerProfile? {
        guard let parameter = components.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
        var base64 = parameter.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return profile(fromDeviceParams: data)
    }

    /// Decodes the fields of `DeviceParams` that describe the optics.
    static func profile(fromDeviceParams data: Data) -> ViewerProfile? {
        var reader = ProtobufReader(data)
        var vendor = ""
        var model = ""
        var screenToLens: Float?
        var lensSeparation: Float?
        var trayToLens: Float = 0.035
        var alignment = ViewerProfile.VerticalAlignment.bottom
        var fieldOfView: [Float] = []
        var coefficients: [Float] = []

        while let field = reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let bytes)): vendor = String(decoding: bytes, as: UTF8.self)
            case (2, .bytes(let bytes)): model = String(decoding: bytes, as: UTF8.self)
            case (3, .fixed32(let bits)): screenToLens = Float(bitPattern: bits)
            case (4, .fixed32(let bits)): lensSeparation = Float(bitPattern: bits)
            case (5, .fixed32(let bits)): fieldOfView.append(Float(bitPattern: bits))
            case (5, .bytes(let bytes)): fieldOfView += ProtobufReader.packedFloats(bytes)
            case (6, .fixed32(let bits)): trayToLens = Float(bitPattern: bits)
            case (7, .fixed32(let bits)): coefficients.append(Float(bitPattern: bits))
            case (7, .bytes(let bytes)): coefficients += ProtobufReader.packedFloats(bytes)
            case (11, .varint(let value)): alignment = ViewerProfile.VerticalAlignment(rawValue: Int(value)) ?? .bottom
            default: break
            }
        }

        // Reject values no real viewer has, so a damaged code cannot produce a broken picture.
        guard let screenToLens, let lensSeparation,
              (0.02...0.1).contains(screenToLens), (0.04...0.08).contains(lensSeparation)
        else { return nil }

        let name = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
        return ViewerProfile(
            name: name.isEmpty ? "Scanned viewer" : name,
            screenToLens: screenToLens,
            lensSeparation: lensSeparation,
            verticalAlignment: alignment,
            trayToLens: trayToLens,
            k1: coefficients.first ?? 0,
            k2: coefficients.count > 1 ? coefficients[1] : 0,
            fieldOfView: min(max(fieldOfView.max() ?? 50, 30), 70)
        )
    }
}

/// Stops at the first redirect that carries viewer parameters, without loading the page.
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var found: ViewerProfile?

    var profile: ViewerProfile? {
        lock.withLock { found }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let profile = CardboardCode.profile(in: components) {
            lock.withLock { found = profile }
            return nil
        }
        return request
    }
}

/// Just enough of the protocol buffer wire format to walk a flat message.
private struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)
    }

    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        // Rebase so offsets start at zero even if `data` is a slice.
        self.data = Data(data)
    }

    mutating func nextField() -> (number: Int, value: Value)? {
        guard let key = readVarint() else { return nil }
        let number = Int(key >> 3)
        switch key & 7 {
        case 0:
            guard let value = readVarint() else { return nil }
            return (number, .varint(value))
        case 1:
            guard let value = readFixed(UInt64.self) else { return nil }
            return (number, .fixed64(value))
        case 2:
            guard let length = readVarint(), offset + Int(length) <= data.count else { return nil }
            defer { offset += Int(length) }
            return (number, .bytes(data.subdata(in: offset..<offset + Int(length))))
        case 5:
            guard let value = readFixed(UInt32.self) else { return nil }
            return (number, .fixed32(value))
        default:
            return nil
        }
    }

    static func packedFloats(_ bytes: Data) -> [Float] {
        var reader = ProtobufReader(bytes)
        var floats: [Float] = []
        while let bits = reader.readFixed(UInt32.self) {
            floats.append(Float(bitPattern: bits))
        }
        return floats
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift < 64 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private mutating func readFixed<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        defer { offset += size }
        return data[offset..<offset + size].withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }
}
