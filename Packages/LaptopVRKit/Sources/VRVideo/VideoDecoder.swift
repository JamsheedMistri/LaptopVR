import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VRProtocol

public enum DecodeOutcome {
    case frame(CVPixelBuffer)
    /// The decoder has no usable reference; ask the sender for a keyframe.
    case needsKeyframe
}

/// Carries a pixel buffer out of VideoToolbox's `@Sendable` output handler.
private final class PixelBufferBox: @unchecked Sendable {
    var buffer: CVPixelBuffer?
}

/// Hardware decoder producing Metal-compatible NV12 buffers. Decoding is synchronous; confine each
/// instance to one queue.
public final class VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    public init() {}

    deinit {
        invalidate()
    }

    public func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        parameterSets = []
    }

    public func decode(_ packet: VideoPacket) -> DecodeOutcome {
        if packet.isKeyframe, !packet.parameterSets.isEmpty, packet.parameterSets != parameterSets {
            configure(parameterSets: packet.parameterSets, codec: packet.codec)
        }
        guard let session, let format, let sampleBuffer = Self.makeSampleBuffer(packet.data, format: format) else {
            return .needsKeyframe
        }

        // With no flags the call is synchronous, so the handler has run by the time it returns.
        let output = PixelBufferBox()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr {
                output.buffer = imageBuffer
            }
        }
        guard status == noErr, let decoded = output.buffer else {
            // Covers a session invalidated by backgrounding as well as corrupt input.
            invalidate()
            return .needsKeyframe
        }
        return .frame(decoded)
    }

    private func configure(parameterSets: [Data], codec: VideoCodec) {
        invalidate()
        guard let format = Self.makeFormat(parameterSets: parameterSets, codec: codec) else { return }

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.session = session
        self.format = format
        self.parameterSets = parameterSets
    }

    private static func makeFormat(parameterSets: [Data], codec: VideoCodec) -> CMVideoFormatDescription? {
        // The CoreMedia calls need an array of pointers, so pin every set while it is in use.
        let pinned = parameterSets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { pinned.forEach { $0.deallocate() } }

        let pointers = pinned.map { UnsafePointer($0.baseAddress!) }
        let sizes = pinned.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let blockBuffer
        else { return nil }

        let copyStatus = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }
        return sampleBuffer
    }
}
