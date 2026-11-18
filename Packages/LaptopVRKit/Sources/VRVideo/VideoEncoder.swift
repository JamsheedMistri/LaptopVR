import CoreMedia
import Foundation
import VideoToolbox
import VRProtocol

public struct VideoEncoderConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var codec: VideoCodec
    public var bitsPerSecond: Int
    public var framesPerSecond: Int

    public init(width: Int, height: Int, codec: VideoCodec, bitsPerSecond: Int, framesPerSecond: Int) {
        self.width = width
        self.height = height
        self.codec = codec
        self.bitsPerSecond = bitsPerSecond
        self.framesPerSecond = framesPerSecond
    }
}

public enum VideoCodingError: Error, Sendable {
    case sessionCreationFailed(OSStatus)
}

/// What the hardware encoders can be asked for. An H.264 session beyond these limits is created
/// without complaint and then drops every frame it is given.
public enum VideoEncoderLimits {
    // H.264 level 5.2, the highest the hardware encoder produces, counted in macroblocks of
    // 16 × 16 pixels.
    private static let h264MacroblocksPerFrame = 36_864
    private static let h264MacroblocksPerSecond = 2_073_600

    /// The highest frame rate at which frames of this size can be encoded, or nil if they are
    /// too large to encode at any rate.
    public static func maxFramesPerSecond(width: Int, height: Int, codec: VideoCodec) -> Int? {
        switch codec {
        case .hevc:
            // Measured up to 4096 × 2560 at 120 frames per second without finding a limit.
            return .max
        case .h264:
            let macroblocks = max(((width + 15) / 16) * ((height + 15) / 16), 1)
            guard macroblocks <= h264MacroblocksPerFrame else { return nil }
            return h264MacroblocksPerSecond / macroblocks
        }
    }
}

/// One compressed frame: length-prefixed NAL units plus, for keyframes, the parameter sets a
/// decoder needs to start from this frame.
public struct EncodedFrame: Sendable {
    public var data: Data
    public var parameterSets: [Data]
    public var isKeyframe: Bool
}

/// Hardware encoder configured for the lowest latency VideoToolbox offers: one frame in, one frame
/// out, no reordering, and no periodic keyframes (they are requested on demand instead, because
/// each one is a bitrate spike).
public final class VideoEncoder: @unchecked Sendable {
    public let configuration: VideoEncoderConfiguration
    /// False when the encoder for this codec rejected low-latency rate control and the session
    /// fell back to ordinary real-time encoding.
    public let usesLowLatencyRateControl: Bool

    private let session: VTCompressionSession

    public init(configuration: VideoEncoderConfiguration) throws {
        self.configuration = configuration
        let codecType = configuration.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC

        func makeSession(lowLatency: Bool) -> (VTCompressionSession?, OSStatus) {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
            if lowLatency {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
            }
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(configuration.width),
                height: Int32(configuration.height),
                codecType: codecType,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            return (session, status)
        }

        var (session, status) = makeSession(lowLatency: true)
        var lowLatency = session != nil
        if session == nil {
            (session, status) = makeSession(lowLatency: false)
            lowLatency = false
        }
        guard let session else { throw VideoCodingError.sessionCreationFailed(status) }
        self.session = session
        usesLowLatencyRateControl = lowLatency

        let profile = configuration.codec == .h264
            ? kVTProfileLevel_H264_High_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true),
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond),
            (kVTCompressionPropertyKey_AverageBitRate, configuration.bitsPerSecond),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Int32.max)),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, 0),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            // Encoders reject properties they do not support; none of these are essential.
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Submits a frame. If this returns true, `handler` runs exactly once on a VideoToolbox
    /// thread, with nil if the encoder dropped the frame. If it returns false, submission failed
    /// and `handler` is never called.
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        forceKeyframe: Bool,
        handler: @escaping @Sendable (EncodedFrame?) -> Void
    ) -> Bool {
        let frameProperties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let codec = configuration.codec
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { status, flags, sampleBuffer in
            guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
                handler(nil)
                return
            }
            handler(EncodedFrame(sampleBuffer: sampleBuffer, codec: codec))
        }
        return status == noErr
    }

    /// Changes the target bitrate without interrupting the stream.
    public func setBitsPerSecond(_ bitsPerSecond: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
    }

    /// Blocks until every submitted frame has been delivered to its handler.
    public func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }
}

extension EncodedFrame {
    init?(sampleBuffer: CMSampleBuffer, codec: VideoCodec) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        // A sample is a sync sample (keyframe) unless explicitly marked otherwise.
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(of: format, codec: codec)
        }

        self.init(data: data, parameterSets: parameterSets, isKeyframe: isKeyframe)
    }

    private static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        func set(at index: Int, count: inout Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }

        var count = 0
        guard let first = set(at: 0, count: &count) else { return [] }
        var sets = [first]
        for index in 1..<max(count, 1) {
            guard let next = set(at: index, count: &count) else { break }
            sets.append(next)
        }
        return sets
    }
}
