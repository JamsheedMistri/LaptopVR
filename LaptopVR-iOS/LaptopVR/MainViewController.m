#import "PTProtocol.h"
#import "MainViewController.h"
#import "StreamLayerViewController.h"
#import "MotionManager.h"
#import <VideoToolbox/VideoToolbox.h>

@interface MainViewController () <PTChannelDelegate> {
    __weak PTChannel *serverChannel_;
    __weak PTChannel *peerChannel_;
}

@property(nonatomic, readonly) BOOL prefersHomeIndicatorAutoHidden;

@end

@implementation MainViewController {
    StreamLayerViewController *leftEye;
    StreamLayerViewController *rightEye;
    MotionManager *motionManager;
    CMVideoFormatDescriptionRef formatDesc;
    int spsSize;
    int ppsSize;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _prefersHomeIndicatorAutoHidden = true;
    
    leftEye = [[StreamLayerViewController alloc] init];
    rightEye = [[StreamLayerViewController alloc] init];
    
    [self.view addSubview:leftEye.view];
    [self.view addSubview:rightEye.view];
    
    int width = self.view.frame.size.width / 2;
    int height = self.view.frame.size.height;
    int notchHeight = 0;
    
    if (@available(iOS 11.0, *)) {
        // In order to get the notch height in landscape mode, take the max of the 2 safe areas
        UIEdgeInsets safeAreaInsets = ((UIWindowScene *)([UIApplication sharedApplication].connectedScenes.allObjects[0])).windows.firstObject.safeAreaInsets;
        notchHeight = MAX(safeAreaInsets.left, safeAreaInsets.right);
    }
    
    // From some reason, x & y origin coordinates for CGRect need to be halved to display correctly on iOS
    leftEye.view.frame = CGRectMake(notchHeight, 0, width - notchHeight, height);
    rightEye.view.frame = CGRectMake(width, 0, width - notchHeight, height);
    leftEye.view.clipsToBounds = YES;
    rightEye.view.clipsToBounds = YES;
    
    // Motion manager
    motionManager = [[MotionManager alloc] init];
    [motionManager enableMotion];
    
    // Create a new channel that is listening on our IPv4 port
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    [channel listenOnPort:PTProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) {
            NSLog(@"Failed to listen on 127.0.0.1:%d: %@", PTProtocolIPv4PortNumber, error);
        } else {
            NSLog(@"Listening on 127.0.0.1:%d", PTProtocolIPv4PortNumber);
            self->serverChannel_ = channel;
        }
    }];
}

#pragma mark - Communicating

- (void)sendDeviceInfo {
    if (!peerChannel_) {
        return;
    }
    
    NSLog(@"Sending device info over %@", peerChannel_);
    
    UIScreen *screen = [UIScreen mainScreen];
    CGSize screenSize = screen.bounds.size;
    NSDictionary *screenSizeDict = (__bridge_transfer NSDictionary*)CGSizeCreateDictionaryRepresentation(screenSize);
    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          device.localizedModel, @"localizedModel",
                          [NSNumber numberWithBool:device.multitaskingSupported], @"multitaskingSupported",
                          device.name, @"name",
                          (UIDeviceOrientationIsLandscape(device.orientation) ? @"landscape" : @"portrait"), @"orientation",
                          device.systemName, @"systemName",
                          device.systemVersion, @"systemVersion",
                          screenSizeDict, @"screenSize",
                          [NSNumber numberWithDouble:screen.scale], @"screenScale",
                          nil];
    dispatch_data_t payload = [info createReferencingDispatchData];
    [peerChannel_ sendFrameOfType:PTDeviceInfo tag:PTFrameNoTag withPayload:(NSData *)payload callback:^(NSError *error) {
        if (error) NSLog(@"Failed to send PTDeviceInfo: %@", error);
    }];
}

#pragma mark - PTChannelDelegate

- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if (channel != peerChannel_) {
        // A previous channel that has been canceled but not yet ended. Ignore.
        return NO;
    } else if (type != PTDesktopFrame && type != PTDeviceInfo) {
        NSLog(@"Unexpected frame of type %u", type);
        [channel close];
        return NO;
    } else {
        return YES;
    }
}

// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
    // Send raw video frame for deserialization
    if (type == PTDesktopFrame) [self receivedRawVideoFrame:payload];
}

// Invoked when the channel closed. If it closed because of an error, *error* is a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    if (error) {
        NSLog(@"%@ ended with error: %@", channel, error);
    } else {
        NSLog(@"Disconnected from %@", channel.userInfo);
    }
}

// For listening channels, this method is invoked when a new connection has been accepted.
- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel fromAddress:(PTAddress*)address {
    // Cancel any other connection. We are FIFO, so the last connection established will cancel any previous connection and "take its place".
    if (peerChannel_) {
        [peerChannel_ cancel];
    }
    
    // Weak pointer to current connection. Connection objects live by themselves (owned by its parent dispatch queue) until they are closed.
    peerChannel_ = otherChannel;
    peerChannel_.userInfo = address;
    NSLog(@"Connected to %@", address);
    
    // Send some information about ourselves to the other end
    [self sendDeviceInfo];
}


#pragma mark - VideoToolbox Decoder

// https://github.com/whiteblue3/HTTPLiveStreaming
- (void) receivedRawVideoFrame:(NSData *)frameData {
    OSStatus status;
    
    uint8_t *data = NULL;
    uint8_t *pps = NULL;
    uint8_t *sps = NULL;
    
    int startCodeIndex = 0;
    int secondStartCodeIndex = 0;
    int thirdStartCodeIndex = 0;
    
    CMSampleBufferRef sampleBuffer = NULL;
    CMBlockBufferRef blockBuffer = NULL;
    
    const uint8_t *frame = frameData.bytes;
    NSUInteger frameSize = frameData.length;
    int offset = 0;
    
    int nalu_type = (frame[startCodeIndex + 4] & 0x1F);
    
    // If SPS/PPS haven't been initialized, we can't process any frames
    if (nalu_type != 7 && formatDesc == NULL) {
        return;
    }
    
    // NALU type 7 - SPS parameter
    if (nalu_type == 7) {
        // Search until we find the next header, which we can use to get SPS length
        for (int i = startCodeIndex + 4; i < startCodeIndex + 40; i++) {
            if (frame[i] == 0x00 && frame[i + 1] == 0x00 && frame[i + 2] == 0x00 && frame[i + 3] == 0x01) {
                secondStartCodeIndex = i;
                spsSize = secondStartCodeIndex;
                break;
            }
        }
        
        // Update NALU to next value
        nalu_type = (frame[secondStartCodeIndex + 4] & 0x1F);
    }
    
    // NALU type 8 - PPS parameter
    if (nalu_type == 8) {
        // Search until we find the next header, which we can use to get PPS length
        for (int i = spsSize + 4; i < spsSize + 30; i++) {
            if (frame[i] == 0x00 && frame[i + 1] == 0x00 && frame[i + 2] == 0x00 && frame[i + 3] == 0x01) {
                thirdStartCodeIndex = i;
                ppsSize = thirdStartCodeIndex - spsSize;
                break;
            }
        }
        
        // Populate SPS and PPS (not including header)
        sps = malloc(spsSize - 4);
        pps = malloc(ppsSize - 4);
        memcpy (sps, &frame[4], spsSize - 4);
        memcpy (pps, &frame[spsSize + 4], ppsSize - 4);
        
        // Form parameter set
        uint8_t*  parameterSetPointers[2] = {sps, pps};
        size_t parameterSetSizes[2] = {spsSize - 4, ppsSize - 4};
        
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets
                 (kCFAllocatorDefault, 2,
                 (const uint8_t *const*) parameterSetPointers,
                 parameterSetSizes, 4,
                 &formatDesc);
        
        offset += spsSize;
        offset += ppsSize;
        
        // Update NALU to next value
        nalu_type = (frame[thirdStartCodeIndex + 4] & 0x1F);
    }
    
    // NALU type 5 - IDR frame
    if (nalu_type == 5) {
        long blockLength = frameSize - offset;
        data = malloc(blockLength);
        data = memcpy(data, &frame[offset], blockLength);
        
        // Replace the header on this NALU with its size.
        // AVCC format requires that you do this.
        // htonl converts the unsigned int from host to network byte order.
        uint32_t dataLength32 = htonl(blockLength - 4);
        memcpy(data, &dataLength32, sizeof (uint32_t));
        
        // Create a block buffer from the IDR NALU
        status = CMBlockBufferCreateWithMemoryBlock
                 (NULL, data,
                  blockLength,
                  kCFAllocatorNull,
                  NULL, 0,
                  blockLength,
                  0, &blockBuffer);
    }
    
    // NALU type 1 - P frame
    if (nalu_type == 1) {
        long blockLength = frameSize - offset;
        data = malloc(blockLength);
        data = memcpy(data, &frame[offset], blockLength);
        
        // Replace the header on this NALU with its size.
        // AVCC format requires that you do this.
        // htonl converts the unsigned int from host to network byte order.
        uint32_t dataLength32 = htonl(blockLength - 4);
        memcpy(data, &dataLength32, sizeof (uint32_t));
        
        status = CMBlockBufferCreateWithMemoryBlock
                 (NULL, data,
                  blockLength,
                  kCFAllocatorNull,
                  NULL, 0,
                  blockLength,
                  0, &blockBuffer);
    }
    
    // Create sample buffer
    if (status == noErr) {
        const size_t sampleSize = frameSize - offset;
        status = CMSampleBufferCreate(kCFAllocatorDefault,
                                      blockBuffer, true, NULL, NULL,
                                      formatDesc, 1, 0, NULL, 1,
                                      &sampleSize, &sampleBuffer);
    }
    
    if (status == noErr) {
        // Setup sample buffer attachment information
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        [self render:sampleBuffer];
    }

    // Clean up
    if (data != NULL) {
        free(data);
        data = NULL;
    }
}

#pragma mark - VideoToolbox -> render bridge

- (void) render:(CMSampleBufferRef)sampleBuffer {
    [leftEye updateFrameWidth:1920 height:1080];
    [rightEye updateFrameWidth:1920 height:1080];
    
    float pitch = [motionManager updateAttitudeAndGetPitch];
    [leftEye updatePitch:pitch];
    [rightEye updatePitch:pitch];
    
    [leftEye enqueueSampleBuffer:sampleBuffer];
    [rightEye enqueueSampleBuffer:sampleBuffer];
    
    CFRelease(sampleBuffer);
}

@end
