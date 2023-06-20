#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

@interface H264Packet : NSObject

+ (NSData *)sampleBufferToH264Packet:(CMSampleBufferRef)sampleBuffer;

@end
