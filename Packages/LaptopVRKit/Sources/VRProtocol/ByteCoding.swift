import Foundation

public enum WireError: Error, Sendable {
    case truncated
    case payloadTooLarge(Int)
    case malformed(String)
}

/// Appends little-endian integers and raw bytes to a `Data`.
struct ByteWriter {
    private(set) var data: Data

    init(capacity: Int = 0) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    /// Writes a 16-bit length followed by the bytes.
    mutating func writeLengthPrefixed(_ bytes: Data) {
        write(UInt16(clamping: bytes.count))
        data.append(bytes.prefix(Int(UInt16.max)))
    }
}

/// Reads little-endian integers and raw bytes from a `Data`, regardless of its start index.
struct ByteReader {
    private let data: Data
    private var cursor: Data.Index

    init(_ data: Data) {
        self.data = data
        cursor = data.startIndex
    }

    var remaining: Int { data.endIndex - cursor }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var value: T = 0
        for offset in 0..<size {
            value |= T(truncatingIfNeeded: data[cursor + offset]) << (8 * offset)
        }
        cursor += size
        return value
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try read(UInt32.self))
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        let slice = data.subdata(in: cursor..<(cursor + count))
        cursor += count
        return slice
    }

    mutating func readLengthPrefixed() throws -> Data {
        let count = Int(try read(UInt16.self))
        return try read(count: count)
    }

    mutating func readRemaining() -> Data {
        let slice = data.subdata(in: cursor..<data.endIndex)
        cursor = data.endIndex
        return slice
    }
}
