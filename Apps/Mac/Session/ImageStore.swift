import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VRProtocol

/// Keeps the pictures the user picks (surroundings and privacy cover) inside the app's own
/// folder, so they stay readable without asking for access to Desktop or Documents every launch.
enum ImageStore {
    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "LaptopVR", directoryHint: .isDirectory)
    }

    /// Copies `source` into the store and returns the copy's path. `replacing` is the previously
    /// stored picture for the same purpose, which is deleted.
    static func importImage(from source: URL, replacing previous: String?) -> String? {
        let destination = directory.appending(path: UUID().uuidString + "." + source.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        if let previous, previous.hasPrefix(directory.path) {
            try? FileManager.default.removeItem(atPath: previous)
        }
        return destination.path
    }

    /// Prepares a picture for the phone: scaled down to what a wrap-around background needs and
    /// recompressed, with an identifier derived from the result.
    static func environmentAsset(atPath path: String) -> AssetMessage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        let output = NSMutableData()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let data = output as Data
        let identifier = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AssetMessage(id: identifier, data: data)
    }
}
