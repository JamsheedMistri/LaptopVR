import ARKit
import simd

/// Camera frames and head position for passthrough, from ARKit world tracking.
///
/// ARKit's poses arrive with the camera frame, tens of milliseconds late, so rendering keeps
/// using `HeadTracker` for rotation. ARKit contributes the picture and the head's position, both
/// converted here into the tracker's world frame.
final class Passthrough: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        /// Focal lengths and principal point (fx, fy, cx, cy) as fractions of the image size.
        let intrinsics: SIMD4<Float>
        /// Rotation from camera axes to the tracker's world when the frame was captured.
        let worldFromCamera: simd_quatf
        /// Head position in the tracker's world, in metres. Nil while ARKit has no fix.
        let position: SIMD3<Float>?
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private let tracker: HeadTracker
    private let session = ARSession()
    private let queue = DispatchQueue(label: "laptopvr.passthrough", qos: .userInteractive)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var frame: Frame?
    private var isRunning = false
    /// Angle about the vertical from ARKit's world to the tracker's world.
    private var heading: Float?

    init(tracker: HeadTracker) {
        self.tracker = tracker
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    var latestFrame: Frame? {
        lock.withLock { frame }
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            defer { isRunning = true }
            return !isRunning
        }
        guard shouldStart, Self.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        // The ultra-wide camera covers much more of what the lenses show.
        let ultraWide = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.captureDeviceType == .builtInUltraWideCamera }
            .max { $0.framesPerSecond < $1.framesPerSecond }
        if let ultraWide {
            configuration.videoFormat = ultraWide
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            defer {
                isRunning = false
                frame = nil
                heading = nil
            }
            return isRunning
        }
        if shouldStop {
            session.pause()
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate arFrame: ARFrame) {
        guard let deviceOrientation = tracker.worldFromDevice(at: arFrame.timestamp) else { return }
        let camera = arFrame.camera

        // The camera's axes are the view axes of a phone held with the home indicator on the right.
        let worldFromCamera = deviceOrientation * simd_quatf(LandscapeSide.right.deviceFromView)

        let transform = camera.transform
        let arFromCamera = simd_quatf(simd_float3x3(columns: (
            transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz
        )))

        let size = camera.imageResolution
        let k = camera.intrinsics
        let intrinsics = SIMD4<Float>(
            k[0][0] / Float(size.width), k[1][1] / Float(size.height),
            k[2][0] / Float(size.width), k[2][1] / Float(size.height)
        )

        var isTracking = false
        if case .normal = camera.trackingState {
            isTracking = true
        }

        lock.withLock {
            guard isRunning else { return }

            // Both worlds are level, so they differ only by a turn about the vertical. Measure
            // it from the two estimates of the same camera pose, and smooth out the noise.
            let forward = (worldFromCamera * arFromCamera.inverse).act(SIMD3(0, 0, -1))
            let measured = atan2(-forward.x, -forward.z)
            let previous = heading ?? measured
            let difference = atan2(sin(measured - previous), cos(measured - previous))
            let smoothed = previous + 0.05 * difference
            heading = smoothed

            let position = isTracking
                ? simd_quatf(angle: smoothed, axis: SIMD3(0, 1, 0)).act(transform.columns.3.xyz)
                : nil
            frame = Frame(
                pixelBuffer: arFrame.capturedImage,
                intrinsics: intrinsics,
                worldFromCamera: worldFromCamera,
                position: position
            )
        }
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
