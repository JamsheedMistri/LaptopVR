import CoreMedia
import Foundation
import ScreenCaptureKit
import VRProtocol
import VRVideo

struct StreamConfiguration: Equatable, Sendable {
    var streamID: UInt16
    var displayID: CGDirectDisplayID
    var width: Int
    var height: Int
    var codec: VideoCodec
    var bitsPerSecond: Int
    var framesPerSecond: Int
    /// Windows to leave out of the capture: the privacy covers.
    var excludedWindowIDs: [CGWindowID]
}

enum StreamError: LocalizedError {
    case displayUnavailable

    var errorDescription: String? {
        "The display is no longer available."
    }
}

/// Nanoseconds on the host clock, the same clock ScreenCaptureKit timestamps frames with.
func hostTimeNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

/// Captures one display, encodes it, and hands encoded frames to `send`.
///
/// Latency is bounded by never letting frames queue. ScreenCaptureKit delivers a frame only when
/// the screen changes; the stream keeps just the newest one, and encodes it when the phone has
/// acknowledged enough earlier frames. A frame that is superseded while waiting is dropped
/// before the encoder sees it, which keeps the encoder's reference chain intact, so no keyframe
/// is needed afterwards. Because the newest frame is kept, the phone always ends up with the
/// screen's final state, and a keyframe can be produced on request while the screen is still.
final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let maxFramesInFlight = 3
    /// If no acknowledgement arrives for this long, assume they were lost with a dead link.
    private static let stalledAfterNanos: UInt64 = 1_000_000_000
    /// An encoder drops the odd frame to keep up. One that drops this many in a row, which
    /// takes most of a second at the least, is never going to produce any.
    private static let hopelessAfterDrops = 120

    private struct CapturedFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let time: CMTime
    }

    private struct Counters {
        var windowStartNanos = hostTimeNanos()
        var frames = 0
        var bytes = 0
        var dropped = 0
        var encodeMillis = 0.0
        var pipelineMillis = 0.0
        var width = 0
        var height = 0

        /// Exponential moving average, seeded by the first sample.
        static func blend(_ average: Double, _ sample: Double) -> Double {
            average == 0 ? sample : average * 0.9 + sample * 0.1
        }
    }

    private let send: @Sendable (WireFrame) -> Void
    private let onFailure: @Sendable (UInt16, String) -> Void
    private let captureQueue = DispatchQueue(label: "laptopvr.capture", qos: .userInteractive)
    private var stream: SCStream?

    // Touched only on `captureQueue`.
    private var encoder: VideoEncoder?
    private var appliedBitsPerSecond = 0
    private var isRetryScheduled = false
    private var reportedEncoderFailure = false

    private let lock = NSLock()
    // Guarded by `lock`.
    private var configuration: StreamConfiguration
    private var latest: CapturedFrame?
    private var latestWasSent = false
    private var nextFrameID: UInt32 = 0
    private var framesInFlight = 0
    private var needsKeyframe = true
    private var lastSubmitNanos: UInt64 = 0
    private var lastAckNanos: UInt64 = 0
    private var dropsInARow = 0
    private var counters = Counters()

    init(
        configuration: StreamConfiguration,
        send: @escaping @Sendable (WireFrame) -> Void,
        onFailure: @escaping @Sendable (UInt16, String) -> Void
    ) {
        self.configuration = configuration
        self.send = send
        self.onFailure = onFailure
    }

    var currentConfiguration: StreamConfiguration {
        lock.withLock { configuration }
    }

    /// The newest captured frame, as it was before encoding. A recording of the view draws it.
    var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { latest?.pixelBuffer }
    }

    // MARK: - Lifecycle

    func start() async throws {
        let configuration = currentConfiguration
        let filter = try await Self.makeFilter(configuration)
        let stream = SCStream(filter: filter, configuration: Self.makeCaptureConfiguration(configuration), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        lock.withLock { latest = nil }
        captureQueue.sync {
            encoder?.finish()
            encoder = nil
        }
    }

    /// Applies a changed configuration for the same display without restarting capture. The
    /// encoder follows by itself: it is rebuilt when the next frame does not match it.
    func update(to new: StreamConfiguration) async throws {
        let old = currentConfiguration
        guard new != old, let stream else { return }

        if new.excludedWindowIDs != old.excludedWindowIDs {
            try await stream.updateContentFilter(try await Self.makeFilter(new))
        }
        if new.width != old.width || new.height != old.height {
            try await stream.updateConfiguration(Self.makeCaptureConfiguration(new))
        }
        lock.withLock { configuration = new }
        submitSoon()
    }

    // MARK: - Feedback from the phone

    func handle(_ ack: VideoAck) {
        let now = hostTimeNanos()
        let hasWork = lock.withLock { () -> Bool in
            framesInFlight = max(0, framesInFlight - 1)
            lastAckNanos = now
            if now > ack.captureTimeNanos {
                let millis = Double(now - ack.captureTimeNanos) / 1_000_000
                counters.pipelineMillis = Counters.blend(counters.pipelineMillis, millis)
            }
            return latest != nil && (!latestWasSent || needsKeyframe)
        }
        // A frame may have been waiting for this acknowledgement.
        if hasWork {
            submitSoon()
        }
    }

    func requestKeyframe() {
        lock.withLock { needsKeyframe = true }
        submitSoon()
    }

    /// Call when the link was replaced: outstanding acknowledgements will never arrive, and the
    /// new link's decoder starts empty.
    func resetForNewLink() {
        lock.withLock {
            framesInFlight = 0
            needsKeyframe = true
        }
        submitSoon()
    }

    /// Returns statistics for the time since the previous call.
    func takeStats() -> StreamStats {
        let now = hostTimeNanos()
        return lock.withLock {
            let seconds = max(Double(now - counters.windowStartNanos) / 1_000_000_000, 0.001)
            let stats = StreamStats(
                stream: configuration.streamID,
                width: counters.width,
                height: counters.height,
                framesPerSecond: Double(counters.frames) / seconds,
                megabitsPerSecond: Double(counters.bytes) * 8 / seconds / 1_000_000,
                encodeMillis: counters.encodeMillis,
                pipelineMillis: counters.pipelineMillis,
                droppedFrames: counters.dropped
            )
            counters.windowStartNanos = now
            counters.frames = 0
            counters.bytes = 0
            counters.dropped = 0
            return stats
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              // Idle and blank frames carry no image; only complete frames have new content.
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        lock.withLock {
            if latest != nil, !latestWasSent {
                counters.dropped += 1
            }
            latest = CapturedFrame(pixelBuffer: pixelBuffer, time: sampleBuffer.presentationTimeStamp)
            latestWasSent = false
        }
        submitLatest()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(currentConfiguration.streamID, error.localizedDescription)
    }

    // MARK: - Encoding

    private func submitSoon() {
        captureQueue.async { [weak self] in
            self?.submitLatest()
        }
    }

    /// Encodes the newest captured frame if it has not been sent, or again if a keyframe is due.
    /// Runs on `captureQueue`.
    private func submitLatest() {
        let now = hostTimeNanos()
        var retryAfterNanos: UInt64?

        let submission = lock.withLock { () -> (frame: CapturedFrame, configuration: StreamConfiguration, frameID: UInt32, keyframe: Bool)? in
            guard let latest, !latestWasSent || needsKeyframe else { return nil }

            // Capture runs at the display's rate, which may be faster than the target.
            let minimumInterval = UInt64(850_000_000 / max(configuration.framesPerSecond, 1))
            let sinceLastSubmit = now - min(lastSubmitNanos, now)
            guard sinceLastSubmit >= minimumInterval else {
                retryAfterNanos = minimumInterval - sinceLastSubmit
                return nil
            }

            if framesInFlight >= Self.maxFramesInFlight {
                // Wait: the next acknowledgement comes back here.
                guard now - min(lastAckNanos, now) > Self.stalledAfterNanos, sinceLastSubmit > Self.stalledAfterNanos else {
                    return nil
                }
                framesInFlight = 0
                needsKeyframe = true
            }

            defer {
                nextFrameID &+= 1
                needsKeyframe = false
            }
            framesInFlight += 1
            lastSubmitNanos = now
            latestWasSent = true
            return (latest, configuration, nextFrameID, needsKeyframe)
        }

        if let retryAfterNanos, !isRetryScheduled {
            isRetryScheduled = true
            captureQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(retryAfterNanos))) { [weak self] in
                self?.isRetryScheduled = false
                self?.submitLatest()
            }
        }
        guard let submission else { return }

        let pixelBuffer = submission.frame.pixelBuffer
        let configuration = submission.configuration
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let (encoder, isNew) = encoder(width: width, height: height, configuration: configuration) else {
            abandonSubmission(wasKeyframe: true)
            return
        }

        let captureNanos = min(Self.hostNanos(of: submission.frame.time) ?? now, now)
        let isKeyframe = submission.keyframe || isNew
        let submitted = encoder.encode(
            pixelBuffer,
            presentationTime: submission.frame.time,
            forceKeyframe: isKeyframe
        ) { [weak self] frame in
            guard let self else { return }
            guard let frame else {
                // The encoder dropped it, so the phone will never acknowledge it.
                self.abandonSubmission(wasKeyframe: isKeyframe)
                if self.shouldRetryAfterDrop(width: width, height: height, configuration: configuration) {
                    self.submitSoon()
                }
                return
            }
            let encodeNanos = hostTimeNanos() - now
            let packet = VideoPacket(
                stream: configuration.streamID,
                frameID: submission.frameID,
                captureTimeNanos: captureNanos,
                encodeMicros: UInt32(clamping: encodeNanos / 1000),
                codec: configuration.codec,
                isKeyframe: frame.isKeyframe,
                width: UInt16(clamping: width),
                height: UInt16(clamping: height),
                parameterSets: frame.parameterSets,
                data: frame.data
            )
            self.lock.withLock {
                self.dropsInARow = 0
                self.counters.frames += 1
                self.counters.bytes += frame.data.count
                self.counters.encodeMillis = Counters.blend(self.counters.encodeMillis, Double(encodeNanos) / 1_000_000)
                self.counters.width = width
                self.counters.height = height
            }
            self.send(packet.frame())
        }
        if !submitted {
            abandonSubmission(wasKeyframe: isKeyframe)
        }
    }

    /// Undoes the bookkeeping for a frame that was never encoded.
    private func abandonSubmission(wasKeyframe: Bool) {
        lock.withLock {
            framesInFlight = max(0, framesInFlight - 1)
            latestWasSent = false
            // The frames before it were encoded, so the next one can still build on them. Only
            // a keyframe that was lost has to be asked for again.
            if wasKeyframe {
                needsKeyframe = true
            }
        }
    }

    /// Counts a frame the encoder dropped. Returns false, after reporting the stream as failed,
    /// once it is clear the encoder will never produce one: trying again would only spin.
    private func shouldRetryAfterDrop(width: Int, height: Int, configuration: StreamConfiguration) -> Bool {
        let drops = lock.withLock { () -> Int in
            dropsInARow += 1
            return dropsInARow
        }
        if drops == Self.hopelessAfterDrops {
            onFailure(
                configuration.streamID,
                "The video encoder produced no picture at \(width) × \(height), \(configuration.framesPerSecond) frames per second.")
        }
        return drops < Self.hopelessAfterDrops
    }

    /// Returns an encoder matching the frame and settings, building a new one when the size,
    /// codec, or frame rate changed. Runs on `captureQueue`.
    private func encoder(width: Int, height: Int, configuration: StreamConfiguration) -> (VideoEncoder, isNew: Bool)? {
        let wanted = VideoEncoderConfiguration(
            width: width, height: height, codec: configuration.codec,
            bitsPerSecond: configuration.bitsPerSecond, framesPerSecond: configuration.framesPerSecond)

        if let encoder {
            var current = encoder.configuration
            current.bitsPerSecond = wanted.bitsPerSecond
            if current == wanted {
                // The bitrate can change without a new encoder, and so without a keyframe.
                if appliedBitsPerSecond != wanted.bitsPerSecond {
                    encoder.setBitsPerSecond(wanted.bitsPerSecond)
                    appliedBitsPerSecond = wanted.bitsPerSecond
                }
                return (encoder, false)
            }
            // Flush, so none of the old encoder's frames are sent after the new one's first.
            encoder.finish()
        }

        do {
            let created = try VideoEncoder(configuration: wanted)
            encoder = created
            appliedBitsPerSecond = wanted.bitsPerSecond
            lock.withLock { dropsInARow = 0 }
            return (created, true)
        } catch {
            encoder = nil
            if !reportedEncoderFailure {
                reportedEncoderFailure = true
                onFailure(configuration.streamID, "The video encoder could not be started.")
            }
            return nil
        }
    }

    // MARK: - Setup helpers

    private static func makeFilter(_ configuration: StreamConfiguration) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw StreamError.displayUnavailable
        }
        let excluded = content.windows.filter { configuration.excludedWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    private static func makeCaptureConfiguration(_ configuration: StreamConfiguration) -> SCStreamConfiguration {
        let capture = SCStreamConfiguration()
        capture.width = configuration.width
        capture.height = configuration.height
        capture.scalesToFit = true
        // Ask for every frame the display produces and pace them when encoding. An interval
        // equal to the display's own would leave it to timing jitter whether ScreenCaptureKit
        // considers a frame too early and holds it back.
        capture.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        // NV12 goes straight into the encoder with no colour conversion.
        capture.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        capture.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        capture.colorSpaceName = CGColorSpace.sRGB
        // Room for the frame being encoded, the newest frame held back, one arriving, and one
        // a recording of the view is still drawing.
        capture.queueDepth = 6
        capture.showsCursor = true
        capture.capturesAudio = false
        return capture
    }

    private static func hostNanos(of time: CMTime) -> UInt64? {
        guard time.isValid, time.seconds > 0 else { return nil }
        let nanos = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        return UInt64(nanos.value)
    }
}
