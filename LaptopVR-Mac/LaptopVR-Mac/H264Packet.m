#import "H264Packet.h"

@implementation H264Packet

// https://github.com/whiteblue3/HTTPLiveStreaming
+ (NSData *)sampleBufferToH264Packet:(CMSampleBufferRef)sampleBuffer {
    NSMutableData *packet = [NSMutableData data];
    NSData *sps, *pps;
    
    // Get format descriptions for the sample buffer, including SPS and PPS info
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    
    size_t spsSize, spsCount;
    const uint8_t *spsPointerOut;
    
    OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &spsPointerOut, &spsSize, &spsCount, 0);
    
    if (statusCode == noErr) {
        // Found SPS, now check for PPS
        size_t ppsSize, ppsCount;
        const uint8_t *ppsPointerOut;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &ppsPointerOut, &ppsSize, &ppsCount, 0);
        
        if (statusCode == noErr) {
            // Found PPS
            sps = [NSData dataWithBytes:spsPointerOut length:spsSize];
            pps = [NSData dataWithBytes:ppsPointerOut length:ppsSize];
            
            // SPS/PPS Header
            const char byteHeaderChars[] = "\x00\x00\x00\x01";
            
            //string literals have implicit trailing '\0'
            size_t length = (sizeof byteHeaderChars) - 1;
            NSData *byteHeader = [NSData dataWithBytes:byteHeaderChars length:length];
            NSMutableData *fullSPSData = [NSMutableData dataWithData:byteHeader];
            NSMutableData *fullPPSData = [NSMutableData dataWithData:byteHeader];
            
            [fullSPSData appendData:sps];
            [fullPPSData appendData:pps];
            
            sps = fullSPSData;
            pps = fullPPSData;
        }
    }
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    
    statusCode = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    
    if (statusCode == noErr) {
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;
        
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            // Read the NAL unit length
            uint32_t NALUnitLength = 0;
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
            
            // Convert the length value from Big-endian to Little-endian
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
            
            NSData* data = [[NSData alloc] initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength) length:NALUnitLength];
            
            // AVC Header
            const char byteHeaderChars[] = "\x00\x00\x00\x01";
            size_t length = (sizeof byteHeaderChars) - 1; //string literals have implicit trailing '\0'
            NSData *byteHeader = [NSData dataWithBytes:byteHeaderChars length:length];
            NSMutableData *fullAVCData = [NSMutableData dataWithData:byteHeader];
            
            [fullAVCData appendData:data];
            
            [packet appendData:sps];
            [packet appendData:pps];
            [packet appendData:fullAVCData];
            
            // Move to the next NAL unit in the block buffer
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
    }
    
    return packet;
}

@end
