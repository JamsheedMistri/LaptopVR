import AppKit
import CoreGraphics

/// A display macOS is currently driving, physical or virtual.
struct DisplayInfo: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    /// Position in the global desktop, in points, with the origin at the main display's top-left.
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    /// Refreshes per second, or 0 when macOS does not say.
    let refreshRate: Double
    let isMain: Bool
    let isBuiltIn: Bool
    /// Serial number of the LaptopVR virtual monitor backing this display, if it is one.
    let virtualSerial: UInt32?
    /// Identifies this display's video stream. The main display is always stream 0.
    let streamID: UInt16

    var isVirtual: Bool { virtualSerial != nil }
}

@MainActor
enum DisplayCatalog {
    /// Lists active displays, main display first, then left to right.
    static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &identifiers, &count)

        let names = Dictionary(
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
                guard let id = screen.displayID else { return nil }
                return (id, screen.localizedName)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var externalIndex: UInt16 = 0
        let displays = identifiers.prefix(Int(count))
            // A display that mirrors another shows nothing of its own.
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { id -> DisplayInfo in
                let isMain = CGDisplayIsMain(id) != 0
                let isOurs = CGDisplayVendorNumber(id) == VirtualDisplayManager.vendorID
                    && CGDisplayModelNumber(id) == VirtualDisplayManager.productID
                let serial = isOurs ? CGDisplaySerialNumber(id) : nil

                let streamID: UInt16
                if isMain {
                    streamID = 0
                } else if let serial {
                    streamID = UInt16(truncatingIfNeeded: serial)
                } else {
                    externalIndex += 1
                    streamID = 100 + externalIndex
                }

                let mode = CGDisplayCopyDisplayMode(id)
                return DisplayInfo(
                    id: id,
                    name: names[id] ?? (isOurs ? "Virtual Monitor" : "Display"),
                    bounds: CGDisplayBounds(id),
                    pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                    pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                    refreshRate: mode?.refreshRate ?? 0,
                    isMain: isMain,
                    isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                    virtualSerial: serial,
                    streamID: streamID
                )
            }

        return displays.sorted { first, second in
            if first.isMain != second.isMain { return first.isMain }
            return first.bounds.minX < second.bounds.minX
        }
    }

    /// Moves a display within the global desktop. macOS adjusts the position so displays stay
    /// edge to edge, so read the catalog again afterwards.
    static func move(_ display: CGDirectDisplayID, to origin: CGPoint) {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success else { return }
        CGConfigureDisplayOrigin(configuration, display, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        CGCompleteDisplayConfiguration(configuration, .permanently)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
