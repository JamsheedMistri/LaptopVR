import CoreMotion
import Foundation
import simd

/// Which way round the phone sits in the viewer.
enum LandscapeSide: Sendable {
    /// Home indicator on the right: the phone's top edge points left.
    case right
    /// Home indicator on the left.
    case left

    /// Rotation from view space (x right, y up, z toward the wearer) to the device's own axes
    /// (x toward the portrait right edge, y toward the top edge, z out of the glass).
    var deviceFromView: simd_float3x3 {
        switch self {
        case .right: simd_float3x3(columns: (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)))
        case .left: simd_float3x3(columns: (SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)))
        }
    }
}

/// Head orientation from the phone's motion sensors.
///
/// Poses are in a world frame with y up and an arbitrary but fixed heading. The latest sample is
/// extrapolated with the gyroscope to the moment a frame will reach the glass, which hides the
/// time rendering and scan-out take; older samples are kept to look up where the head was when a
/// camera frame was captured.
final class HeadTracker: @unchecked Sendable {
    private struct Sample {
        var time: TimeInterval
        /// Rotation from device axes to world axes.
        var worldFromDevice: simd_quatf
        /// Radians per second about the device's axes.
        var rotationRate: SIMD3<Float>
    }

    /// Longest extrapolation. Beyond this the gyroscope reading is too stale to trust.
    private static let maxPrediction: TimeInterval = 0.04
    private static let historyLength = 64

    /// Core Motion's reference frame has z up; turn it so y is up.
    private static let worldFromReference = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private let lock = NSLock()
    // Oldest first. Guarded by `lock`.
    private var history: [Sample] = []

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            // The attitude matrix takes reference-frame vectors into the device frame; its
            // transpose is therefore the device's axes as seen from the reference frame.
            let m = motion.attitude.rotationMatrix
            let referenceFromDevice = simd_float3x3(columns: (
                SIMD3(Float(m.m11), Float(m.m12), Float(m.m13)),
                SIMD3(Float(m.m21), Float(m.m22), Float(m.m23)),
                SIMD3(Float(m.m31), Float(m.m32), Float(m.m33))
            ))
            let sample = Sample(
                time: motion.timestamp,
                worldFromDevice: Self.worldFromReference * simd_quatf(referenceFromDevice),
                rotationRate: SIMD3(Float(motion.rotationRate.x), Float(motion.rotationRate.y), Float(motion.rotationRate.z))
            )
            self.lock.withLock {
                self.history.append(sample)
                if self.history.count > Self.historyLength {
                    self.history.removeFirst()
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.withLock { history = [] }
    }

    /// Device orientation at `time`, on the same clock as `CACurrentMediaTime()`. Returns nil
    /// until the first sample arrives.
    func worldFromDevice(at time: TimeInterval) -> simd_quatf? {
        lock.withLock {
            guard let latest = history.last else { return nil }

            if time >= latest.time {
                let ahead = Float(min(time - latest.time, Self.maxPrediction))
                let speed = simd_length(latest.rotationRate)
                guard speed > 1e-4 else { return latest.worldFromDevice }
                // The rate is about the device's own axes, so it applies on the right.
                return latest.worldFromDevice * simd_quatf(angle: speed * ahead, axis: latest.rotationRate / speed)
            }

            guard let after = history.firstIndex(where: { $0.time >= time }), after > 0 else {
                return history[0].worldFromDevice
            }
            let earlier = history[after - 1]
            let later = history[after]
            let fraction = Float((time - earlier.time) / max(later.time - earlier.time, 1e-6))
            return simd_slerp(earlier.worldFromDevice, later.worldFromDevice, fraction)
        }
    }
}
