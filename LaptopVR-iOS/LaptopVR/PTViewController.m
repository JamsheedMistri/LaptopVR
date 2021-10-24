#import "PTProtocol.h"
#import "PTViewController.h"

@interface PTViewController () <
PTChannelDelegate,
UITextFieldDelegate
> {
    __weak PTChannel *serverChannel_;
    __weak PTChannel *peerChannel_;
}

@property (weak, nonatomic) IBOutlet UIView *parentView;
@property (weak, nonatomic) IBOutlet UIImageView *leftEye;
@property (weak, nonatomic) IBOutlet UIImageView *rightEye;

@property(nonatomic, readonly) BOOL prefersHomeIndicatorAutoHidden;

@end

@implementation PTViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _prefersHomeIndicatorAutoHidden = true;
    
    [_leftEye.trailingAnchor constraintEqualToAnchor:_parentView.centerXAnchor].active = YES;
    [_rightEye.leadingAnchor constraintEqualToAnchor:_parentView.centerXAnchor].active = YES;
    
    // Create a new channel that is listening on our IPv4 port
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    [channel listenOnPort:PTExampleProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) {
            [self appendOutputMessage:[NSString stringWithFormat:@"Failed to listen on 127.0.0.1:%d: %@", PTExampleProtocolIPv4PortNumber, error]];
        } else {
            [self appendOutputMessage:[NSString stringWithFormat:@"Listening on 127.0.0.1:%d", PTExampleProtocolIPv4PortNumber]];
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
    [peerChannel_ sendFrameOfType:PTExampleFrameTypeDeviceInfo tag:PTFrameNoTag withPayload:(NSData *)payload callback:^(NSError *error) {
        if (error) {
            NSLog(@"Failed to send PTExampleFrameTypeDeviceInfo: %@", error);
        }
    }];
}

#pragma mark - PTChannelDelegate

// Invoked to accept an incoming frame on a channel. Reply NO ignore the
// incoming frame. If not implemented by the delegate, all frames are accepted.
- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if (channel != peerChannel_) {
        // A previous channel that has been canceled but not yet ended. Ignore.
        return NO;
    } else if (type != PTDesktopFrame && type != PTExampleFrameTypeDeviceInfo) {
        NSLog(@"Unexpected frame of type %u", type);
        [channel close];
        return NO;
    } else {
        return YES;
    }
}

// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
    if (type == PTDesktopFrame) {
        CMSampleBufferRef sampleBuffer;
        [self createCMSampleBuffer:&sampleBuffer fromData:payload];
        [_leftEye setImage:[self imageFromSampleBuffer:sampleBuffer]];
        [_rightEye setImage:[self imageFromSampleBuffer:sampleBuffer]];
        CFRelease(sampleBuffer);
    }
}

// https://github.com/Mikael-Lovqvist/obs-studio/blob/3cd5742be5168f625558c14c1b38fedf23116277/plugins/mac-virtualcam/src/dal-plugin/CMSampleBufferUtils.mm
- (void) createCMSampleBuffer:(CMSampleBufferRef *)sampleBuffer fromData:(NSData *)data
{
    OSStatus err = noErr;
    long width = 0;
    long height = 0;
    OSType pixelFormat = 0;
    
    [data getBytes:&width range:NSMakeRange(0, sizeof(long))];
    [data getBytes:&height range:NSMakeRange(sizeof(long), sizeof(long))];
    [data getBytes:&pixelFormat range:NSMakeRange(sizeof(long) * 2, sizeof(UInt32))];
    
    // Create an empty pixel buffer
    CVPixelBufferRef pixelBuffer;
    err = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              pixelFormat, nil,
                              &pixelBuffer);
    if (err != noErr) {
        NSLog(@"CVPixelBufferCreate err %d", err);
        return;
    }
    
    // Generate the video format description from that pixel buffer
    CMFormatDescriptionRef format;
    err = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer,
                                                       &format);
    if (err != noErr) {
        NSLog(@"CMVideoFormatDescriptionCreateForImageBuffer err %d",
              err);
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
    
    // TODO change
    uint64_t timestampNanos = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0 * 1000.0 * 1000.0);
    uint32_t fpsDenominator = 1;
    uint32_t fpsNumerator = 30;
    
    CMTimeScale scale = 600;
    CMSampleTimingInfo timing;
    timing.duration =
    CMTimeMake(fpsDenominator * scale, fpsNumerator * scale);
    timing.presentationTimeStamp = CMTimeMake(
                                              (timestampNanos / (double)NSEC_PER_SEC) * scale, scale);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                   pixelBuffer, format, &timing, sampleBuffer);
    CFRelease(format);
    CFRelease(pixelBuffer);
    
    if (err != noErr) {
        NSLog(@"CMIOSampleBufferCreateForImageBuffer err %d", err);
        return;
    }
}

// https://stackoverflow.com/questions/14383932/convert-cmsamplebufferref-to-uiimage
-(UIImage *) imageFromSampleBuffer:(CMSampleBufferRef)samImageBuff
{
    CVImageBufferRef imageBuffer =
    CMSampleBufferGetImageBuffer(samImageBuff);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext
                             createCGImage:ciImage
                             fromRect:CGRectMake(0, 0,
                                                 CVPixelBufferGetWidth(imageBuffer),
                                                 CVPixelBufferGetHeight(imageBuffer))];
    
    UIImage *image = [[UIImage alloc] initWithCGImage:videoImage];
    CGImageRelease(videoImage);
    return image;
}


// Invoked when the channel closed. If it closed because of an error, *error* is
// a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    if (error) {
        [self appendOutputMessage:[NSString stringWithFormat:@"%@ ended with error: %@", channel, error]];
    } else {
        [self appendOutputMessage:[NSString stringWithFormat:@"Disconnected from %@", channel.userInfo]];
    }
}

// For listening channels, this method is invoked when a new connection has been
// accepted.
- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel fromAddress:(PTAddress*)address {
    // Cancel any other connection. We are FIFO, so the last connection
    // established will cancel any previous connection and "take its place".
    if (peerChannel_) {
        [peerChannel_ cancel];
    }
    
    // Weak pointer to current connection. Connection objects live by themselves
    // (owned by its parent dispatch queue) until they are closed.
    peerChannel_ = otherChannel;
    peerChannel_.userInfo = address;
    [self appendOutputMessage:[NSString stringWithFormat:@"Connected to %@", address]];
    
    // Send some information about ourselves to the other end
    [self sendDeviceInfo];
}


@end
