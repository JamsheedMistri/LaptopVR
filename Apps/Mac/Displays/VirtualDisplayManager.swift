import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// Creates and removes virtual monitors. macOS treats each one as a real external display, so the
/// desktop extends onto it and windows can be dragged there.
///
/// This is the only code that touches the private `CGVirtualDisplay` API.
@MainActor
final class VirtualDisplayManager {
    /// Identity reported to macOS. It lets the app recognise its own displays, and macOS uses it
    /// to remember each monitor's position in the arrangement between sessions.
    static let vendorID: UInt32 = 0x4C56 // "LV"
    static let productID: UInt32 = 0x5652 // "VR"

    private struct Entry {
        let spec: VirtualMonitorSpec
        let display: CGVirtualDisplay
    }

    private var entries: [UInt32: Entry] = [:]
    /// Monitors created since the last `waitUntilSettled`, which still have to be given their mode.
    private var unsettled: Set<UInt32> = []

    var isEmpty: Bool { entries.isEmpty }

    /// Serial numbers of live monitors that `sync(with:)` would remove or recreate.
    func staleSerials(for specs: [VirtualMonitorSpec]) -> [UInt32] {
        let wanted = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { wanted[$0.key] != $0.value.spec }.map(\.key)
    }

    /// Makes the set of live virtual monitors match `specs`, and returns whether anything
    /// changed. A virtual display exists for as long as its object is retained, so removing one
    /// is just releasing it.
    @discardableResult
    func sync(with specs: [VirtualMonitorSpec]) -> Bool {
        var changed = false
        for id in staleSerials(for: specs) {
            entries[id] = nil
            unsettled.remove(id)
            changed = true
        }
        for spec in specs where entries[spec.id] == nil {
            if let display = Self.makeDisplay(spec) {
                entries[spec.id] = Entry(spec: spec, display: display)
                unsettled.insert(spec.id)
                changed = true
            }
        }
        return changed
    }

    func removeAll() {
        entries = [:]
        unsettled = []
    }

    /// Waits for macOS to finish adding or removing displays after `sync`, and puts each new
    /// monitor in the mode it was asked for.
    func waitUntilSettled(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        var requested: Set<UInt32> = []
        while ContinuousClock.now < deadline {
            let expected = Set(entries.keys)
            let online = Set(DisplayCatalog.current().compactMap(\.virtualSerial))
            if expected == online {
                let waiting = unsettled.filter { serial in
                    entries[serial].map { !Self.isInOwnMode($0) } ?? false
                }
                if waiting.isEmpty { break }
                // Asked for once; the loop then waits for macOS to get there.
                requested.formUnion(selectOwnModes(of: waiting.subtracting(requested)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        unsettled = []
        // The window server keeps rearranging for a moment after the display list changes.
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Modes

    /// macOS brings a new display up in its largest mode at one pixel per point: a "1440 × 900
    /// Retina" monitor arrives as 2880 × 1800 with text half the intended size. This switches
    /// the given monitors to the mode they were created for, and returns those it could ask.
    private func selectOwnModes(of serials: Set<UInt32>) -> Set<UInt32> {
        var configuration: CGDisplayConfigRef?
        var asked: Set<UInt32> = []
        for serial in serials {
            guard let entry = entries[serial], let mode = Self.ownMode(of: entry) else { continue }
            if configuration == nil, CGBeginDisplayConfiguration(&configuration) != .success {
                return []
            }
            if CGConfigureDisplayWithDisplayMode(configuration, entry.display.displayID, mode, nil) == .success {
                asked.insert(serial)
            }
        }
        if let configuration {
            // Permanently, so macOS remembers and the monitor arrives in this mode next time.
            CGCompleteDisplayConfiguration(configuration, .permanently)
        }
        return asked
    }

    private static func isInOwnMode(_ entry: Entry) -> Bool {
        CGDisplayCopyDisplayMode(entry.display.displayID).map { matches($0, entry.spec) } ?? false
    }

    private static func ownMode(of entry: Entry) -> CGDisplayMode? {
        // Without this option the list leaves out the Retina modes.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(entry.display.displayID, options) as? [CGDisplayMode] ?? []
        return modes.first { matches($0, entry.spec) }
    }

    private static func matches(_ mode: CGDisplayMode, _ spec: VirtualMonitorSpec) -> Bool {
        mode.width == spec.width && mode.height == spec.height
            && mode.pixelWidth == spec.width * (spec.hiDPI ? 2 : 1)
    }

    // MARK: - Creation

    private static func makeDisplay(_ spec: VirtualMonitorSpec) -> CGVirtualDisplay? {
        let scale: UInt32 = spec.hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "LaptopVR Monitor \(spec.id)"
        descriptor.vendorID = vendorID
        descriptor.productID = productID
        descriptor.serialNum = spec.id
        descriptor.maxPixelsWide = UInt32(spec.width) * scale
        descriptor.maxPixelsHigh = UInt32(spec.height) * scale
        // Roughly a 27-inch panel; only affects the size macOS reports.
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 600 * Double(spec.height) / Double(spec.width))
        // sRGB primaries and D65 white point.
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt32(spec.width), height: UInt32(spec.height), refreshRate: 60),
        ]
        guard display.apply(settings) else { return nil }
        return display
    }
}
