#import "PTProtocol.h"
#import "MainViewController.h"
#import "zlib.h"
#import "StreamLayerViewController.h"
#import "MotionManager.h"

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
        notchHeight = MAX(UIApplication.sharedApplication.windows.firstObject.safeAreaInsets.left, UIApplication.sharedApplication.windows.firstObject.safeAreaInsets.right);
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
            [self appendOutputMessage:[NSString stringWithFormat:@"Failed to listen on 127.0.0.1:%d: %@", PTProtocolIPv4PortNumber, error]];
        } else {
            [self appendOutputMessage:[NSString stringWithFormat:@"Listening on 127.0.0.1:%d", PTProtocolIPv4PortNumber]];
            self->serverChannel_ = channel;
        }
    }];
}

- (void)appendOutputMessage:(NSString*)message {
    NSLog(@">> %@", message);
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
        if (error) {
            NSLog(@"Failed to send PTDeviceInfo: %@", error);
        }
    }];
}

#pragma mark - PTChannelDelegate

// Invoked to accept an incoming frame on a channel. Reply NO ignore the incoming frame. If not implemented by the delegate, all frames are accepted.
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

// https://stackoverflow.com/questions/8425012/is-there-a-practical-way-to-compress-nsdata
- (NSData *)gzipInflate:(NSData*)data {
    if ([data length] == 0) return data;

    unsigned full_length = [data length];
    unsigned half_length = [data length] / 2;

    NSMutableData *decompressed = [NSMutableData dataWithLength: full_length + half_length];
    BOOL done = NO;
    int status;

    z_stream strm;
    strm.next_in = (Bytef *)[data bytes];
    strm.avail_in = [data length];
    strm.total_out = 0;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;

    if (inflateInit2(&strm, (15+32)) != Z_OK) return nil;
    while (!done) {
        // Make sure we have enough room and reset the lengths.
        if (strm.total_out >= [decompressed length])
            [decompressed increaseLengthBy: half_length];
        strm.next_out = [decompressed mutableBytes] + strm.total_out;
        strm.avail_out = [decompressed length] - strm.total_out;

        // Inflate another chunk.
        status = inflate (&strm, Z_SYNC_FLUSH);
        if (status == Z_STREAM_END) done = YES;
        else if (status != Z_OK) break;
    }
    if (inflateEnd (&strm) != Z_OK) return nil;

    // Set real length
    if (done) {
        [decompressed setLength: strm.total_out];
        return [NSData dataWithData: decompressed];
    }
    else return nil;
}

// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
    if (type == PTDesktopFrame) {
        CMSampleBufferRef sampleBuffer;
        sampleBuffer = [self createh264SampleBufferFromFrame:payload];
        
        // Tell sampleBuffer to display immediately
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);

        [leftEye updateFrameWidth:1920 height:1080];
        [rightEye updateFrameWidth:1920 height:1080];
        
        [leftEye enqueueSampleBuffer:sampleBuffer];
        [rightEye enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

// https://github.com/ideawu/ios_live_streaming/blob/c7262d92c0e0f00e4dddaa8d4b745e1640f46f54/irtc/h264/VideoDecoder.m
- (CMSampleBufferRef)createh264SampleBufferFromFrame:(NSData *)data {
    
    size_t sps_size = 0;
    size_t pps_size = 0;
    
        
    [data getBytes:&sps_size range:NSMakeRange(0, sizeof(size_t))];
    [data getBytes:&pps_size range:NSMakeRange(sizeof(size_t), sizeof(size_t))];
    
    NSData* sps = [NSData dataWithBytes:[data bytes] + (sizeof(size_t) * 2) length:sps_size];
    NSData* pps = [NSData dataWithBytes:[data bytes] + ((sizeof(size_t) * 2) + sps_size) length:pps_size];
    
    uint8_t*  arr[2] = {(uint8_t*)sps.bytes, (uint8_t*)pps.bytes};
    size_t sizes[2] = {sps.length, sps.length};
    
    CMFormatDescriptionRef format;
    OSStatus formatErr;
    formatErr = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2,
                                                                 (const uint8_t *const*)arr,
                                                                 sizes, 4,
                                                                 &format);

    float pitch = [motionManager updateAttitudeAndGetPitch];
    [leftEye updatePitch:pitch];
    [rightEye updatePitch:pitch];
    
    long offset = (sizeof(size_t) * 2) + sps_size + pps_size;
    NSData *frame = [NSData dataWithBytes:[data bytes] + offset length:data.length - offset];
    
    CMSampleBufferRef sampleBuffer = NULL;
    CMBlockBufferRef blockBuffer = NULL;
    size_t length = frame.length;
    OSStatus err;
    err = CMBlockBufferCreateWithMemoryBlock(NULL,
                                             NULL,
                                             length,
                                             kCFAllocatorDefault,
                                             NULL,
                                             0,
                                             length,
                                             kCMBlockBufferAssureMemoryNowFlag,
                                             &blockBuffer);
    if (err == 0) {
        err = CMBlockBufferReplaceDataBytes(frame.bytes, blockBuffer, 0, length);
    }
    
    if (err == 0) {
        uint64_t timestampNanos = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0 * 1000.0 * 1000.0);
        uint32_t fpsDenominator = 1;
        uint32_t fpsNumerator = 30;

        CMTimeScale scale = 600;
        CMSampleTimingInfo timing;
        timing.duration =
        CMTimeMake(fpsDenominator * scale, fpsNumerator * scale);
        timing.presentationTimeStamp = CMTimeMake((timestampNanos / (double)NSEC_PER_SEC) * scale, scale);
        timing.decodeTimeStamp = kCMTimeInvalid;
        


        err = CMSampleBufferCreate(kCFAllocatorDefault,
                                   blockBuffer,
                                   true, NULL, NULL,
                                   format,
                                   1, // num samples
                                   1, &timing,
                                   1, &length,
                                   &sampleBuffer);
    }
    if (err != 0) {
        NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
    }

    if (blockBuffer) {
        CFRelease(blockBuffer);
    }

    return sampleBuffer;
}

// https://github.com/Mikael-Lovqvist/obs-studio/blob/3cd5742be5168f625558c14c1b38fedf23116277/plugins/mac-virtualcam/src/dal-plugin/CMSampleBufferUtils.mm
- (void) createCMSampleBuffer:(CMSampleBufferRef *)sampleBuffer fromData:(NSData *)data
{
    OSStatus err = noErr;
    long width = 0;
    long height = 0;
    OSType pixelFormat = 0;
    
    int widthHeightSize = sizeof(long);
    int pixelFormatSize = sizeof(UInt32);
    
    [data getBytes:&width range:NSMakeRange(0, widthHeightSize)];
    [data getBytes:&height range:NSMakeRange(widthHeightSize, widthHeightSize)];
    [data getBytes:&pixelFormat range:NSMakeRange(widthHeightSize * 2, pixelFormatSize)];
    
    [leftEye updateFrameWidth:(int)width height:(int)height];
    [rightEye updateFrameWidth:(int)width height:(int)height];
    float pitch = [motionManager updateAttitudeAndGetPitch];
    [leftEye updatePitch:pitch];
    [rightEye updatePitch:pitch];
    
    // Create an empty pixel buffer
    CVPixelBufferRef pixelBuffer;
    err = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &pixelBuffer);
    if (err != noErr) {
        NSLog(@"CVPixelBufferCreate err %d", err);
        return;
    }
    
    // Generate the video format description from that pixel buffer
    CMFormatDescriptionRef format;
    err = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &format);
    if (err != noErr) {
        NSLog(@"CMVideoFormatDescriptionCreateForImageBuffer err %d", err);
        return;
    }
    
    // Copy memory into the pixel buffer
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dest =
    (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    uint8_t *src = (uint8_t *)data.bytes;
    src += (sizeof(long) * 2) + sizeof(OSType);
    
    size_t destBytesPerRow =
    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t srcBytesPerRow = width * 2;
    
    // Sometimes CVPixelBufferCreate will create a pixelbuffer that's a different
    // size than necessary to hold the frame (probably for some optimization reason).
    // If that is the case this will do a row-by-row copy into the buffer.
    if (destBytesPerRow == srcBytesPerRow) {
        memcpy(dest, src, data.length - ((sizeof(long) * 2) + sizeof(OSType)));
    } else {
        for (int line = 0; line < height; line++) {
            memcpy(dest, src, srcBytesPerRow);
            src += srcBytesPerRow;
            dest += destBytesPerRow;
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    uint64_t timestampNanos = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0 * 1000.0 * 1000.0);
    uint32_t fpsDenominator = 1;
    uint32_t fpsNumerator = 30;
    
    CMTimeScale scale = 600;
    CMSampleTimingInfo timing;
    timing.duration =
    CMTimeMake(fpsDenominator * scale, fpsNumerator * scale);
    timing.presentationTimeStamp = CMTimeMake((timestampNanos / (double)NSEC_PER_SEC) * scale, scale);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format, &timing, sampleBuffer);
    CFRelease(format);
    CFRelease(pixelBuffer);
    
    if (err != noErr) {
        NSLog(@"CMIOSampleBufferCreateForImageBuffer err %d", err);
        return;
    }
}

// Invoked when the channel closed. If it closed because of an error, *error* is a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    if (error) {
        [self appendOutputMessage:[NSString stringWithFormat:@"%@ ended with error: %@", channel, error]];
    } else {
        [self appendOutputMessage:[NSString stringWithFormat:@"Disconnected from %@", channel.userInfo]];
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
    [self appendOutputMessage:[NSString stringWithFormat:@"Connected to %@", address]];
    
    // Send some information about ourselves to the other end
    [self sendDeviceInfo];
}

@end
