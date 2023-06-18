#import "AppDelegate.h"
#import "PTProtocol.h"
#import <peertalk/PTProtocol.h>
#import <peertalk/PTUSBHub.h>
#import <QuartzCore/QuartzCore.h>
#import "zlib.h"
#import <VideoToolbox/VideoToolbox.h>

@interface AppDelegate () {
    NSNumber *connectingToDeviceID_;
    NSNumber *connectedDeviceID_;
    NSDictionary *connectedDeviceProperties_;
    NSDictionary *remoteDeviceInfo_;
    dispatch_queue_t notConnectedQueue_;
    BOOL notConnectedQueueSuspended_;
    PTChannel *connectedChannel_;
    NSDictionary *consoleTextAttributes_;
    NSDictionary *consoleStatusTextAttributes_;
    long currentIndex;
    long highestIndex;
}

@property (readonly) NSNumber *connectedDeviceID;
@property PTChannel *connectedChannel;
@property (weak) IBOutlet NSTextField *infoLabel;
@property (weak) IBOutlet NSButton *startButton;

- (void)presentMessage:(NSString*)message isStatus:(BOOL)isStatus;
- (void)startListeningForDevices;
- (void)didDisconnectFromDevice:(NSNumber*)deviceID;
- (void)disconnectFromCurrentChannel;
- (void)enqueueConnectToLocalIPv4Port;
- (void)connectToLocalIPv4Port;
- (void)connectToUSBDevice;

@end

@implementation AppDelegate {
    CGDirectDisplayID display;
    AVCaptureVideoDataOutput *outputDevice;
    NSMutableArray *shadeWindows;
    BOOL isCurrentlyStreaming;
}

@synthesize window = window_;
@synthesize connectedDeviceID = connectedDeviceID_;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // We use a serial queue that we toggle depending on if we are connected or not. When we are not connected to a peer, the queue is running to handle "connect" tries. When we are connected to a peer, the queue is suspended thus no longer trying to connect.
    notConnectedQueue_ = dispatch_queue_create("PTExample.notConnectedQueue", DISPATCH_QUEUE_SERIAL);
    isCurrentlyStreaming = false;
    
    // Start listening for device attached/detached notifications
    [self startListeningForDevices];
    
    // Start trying to connect to local IPv4 port (defined in PTExampleProtocol.h)
    [self enqueueConnectToLocalIPv4Port];
    
    // Put a little message in the UI
    [self presentMessage:@"Ready for action — connecting at will." isStatus:YES];
}

- (IBAction)startStream:(id)sender {
    if (isCurrentlyStreaming) {
        [self.captureSession stopRunning];
        [_startButton setTitle:@"Start LaptopVR"];
        isCurrentlyStreaming = false;
    } else {
        [self createCaptureSession];
        [self.captureSession startRunning];
        [_startButton setTitle:@"Stop LaptopVR"];
        isCurrentlyStreaming = true;
    }
}

- (void)presentMessage:(NSString*)message isStatus:(BOOL)isStatus {
    NSLog(@">> %@", message);
}

- (PTChannel*)connectedChannel {
    return connectedChannel_;
}

- (void)setConnectedChannel:(PTChannel*)connectedChannel {
    connectedChannel_ = connectedChannel;
    
    // Toggle the notConnectedQueue_ depending on if we are connected or not
    if (!connectedChannel_ && notConnectedQueueSuspended_) {
        dispatch_resume(notConnectedQueue_);
        notConnectedQueueSuspended_ = NO;
    } else if (connectedChannel_ && !notConnectedQueueSuspended_) {
        dispatch_suspend(notConnectedQueue_);
        notConnectedQueueSuspended_ = YES;
    }
    
    if (!connectedChannel_ && connectingToDeviceID_) {
        [self enqueueConnectToUSBDevice];
    }
}

#pragma mark - PTChannelDelegate

- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if (type != PTDeviceInfo && type != PTFrameTypeEndOfStream) {
        NSLog(@"Unexpected frame of type %u", type);
        [channel close];
        return NO;
    } else {
        return YES;
    }
}

- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
    if (type == PTDeviceInfo) {
        NSDictionary *deviceInfo = [NSData dictionaryWithContentsOfData:payload];
        [self presentMessage:[NSString stringWithFormat:@"Connected to %@", deviceInfo.description] isStatus:YES];
        [_startButton setEnabled:true];
        // TODO: change "device" to actual device name
        _infoLabel.stringValue = [NSString stringWithFormat:@"Connected to device"];
        [_startButton setTitle:@"Start LaptopVR"];
        isCurrentlyStreaming = false;
    }
}

- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    if (connectedDeviceID_ && [connectedDeviceID_ isEqualToNumber:channel.userInfo]) {
        [self didDisconnectFromDevice:connectedDeviceID_];
    }
    
    if (connectedChannel_ == channel) {
        [self presentMessage:[NSString stringWithFormat:@"Disconnected from %@", channel.userInfo] isStatus:YES];
        self.connectedChannel = nil;
        if (isCurrentlyStreaming) {
            [self.captureSession stopRunning];
        }
        [_startButton setEnabled:false];
        _infoLabel.stringValue = @"Waiting for device to connect...";
        [_startButton setTitle:@"Start LaptopVR"];
        isCurrentlyStreaming = false;
    }
}

#pragma mark - Wired device connections

- (void)startListeningForDevices {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    [nc addObserverForName:PTUSBDeviceDidAttachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
        NSLog(@"PTUSBDeviceDidAttachNotification: %@", deviceID);
        
        dispatch_async(self->notConnectedQueue_, ^{
            if (!self->connectingToDeviceID_ || ![deviceID isEqualToNumber:self->connectingToDeviceID_]) {
                [self disconnectFromCurrentChannel];
                self->connectingToDeviceID_ = deviceID;
                self->connectedDeviceProperties_ = [note.userInfo objectForKey:PTUSBHubNotificationKeyProperties];
                [self enqueueConnectToUSBDevice];
            }
        });
    }];
    
    [nc addObserverForName:PTUSBDeviceDidDetachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
        NSLog(@"PTUSBDeviceDidDetachNotification: %@", deviceID);
        
        if ([self->connectingToDeviceID_ isEqualToNumber:deviceID]) {
            self->connectedDeviceProperties_ = nil;
            self->connectingToDeviceID_ = nil;
            if (self->connectedChannel_) {
                [self->connectedChannel_ close];
            }
        }
    }];
}

- (void)didDisconnectFromDevice:(NSNumber*)deviceID {
    NSLog(@"Disconnected from device");
    if ([connectedDeviceID_ isEqualToNumber:deviceID]) {
        [self willChangeValueForKey:@"connectedDeviceID"];
        connectedDeviceID_ = nil;
        [self didChangeValueForKey:@"connectedDeviceID"];
    }
}

- (void)disconnectFromCurrentChannel {
    if (connectedDeviceID_ && connectedChannel_) {
        [connectedChannel_ close];
        self.connectedChannel = nil;
    }
}

- (void)enqueueConnectToLocalIPv4Port {
    dispatch_async(notConnectedQueue_, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToLocalIPv4Port];
        });
    });
}

- (void)connectToLocalIPv4Port {
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    channel.userInfo = [NSString stringWithFormat:@"127.0.0.1:%d", PTProtocolIPv4PortNumber];
    [channel connectToPort:PTProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, PTAddress *address) {
        if (error) {
            if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
                // this is an expected state
            } else {
                NSLog(@"Failed to connect to 127.0.0.1:%d: %@", PTProtocolIPv4PortNumber, error);
            }
        } else {
            [self disconnectFromCurrentChannel];
            self.connectedChannel = channel;
            channel.userInfo = address;
            NSLog(@"Connected to %@", address);
        }
        [self performSelector:@selector(enqueueConnectToLocalIPv4Port) withObject:nil afterDelay:PTAppReconnectDelay];
    }];
}

- (void)enqueueConnectToUSBDevice {
    dispatch_async(notConnectedQueue_, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToUSBDevice];
        });
    });
}

- (void)connectToUSBDevice {
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    channel.userInfo = connectingToDeviceID_;
    channel.delegate = self;
    
    [channel connectToPort:PTProtocolIPv4PortNumber overUSBHub:PTUSBHub.sharedHub deviceID:connectingToDeviceID_ callback:^(NSError *error) {
        if (error) {
            if (error.domain == PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused) {
                NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
            } else {
                NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
            }
            if (channel.userInfo == self->connectingToDeviceID_) {
                [self performSelector:@selector(enqueueConnectToUSBDevice) withObject:nil afterDelay:PTAppReconnectDelay];
            }
        } else {
            self->connectedDeviceID_ = self->connectingToDeviceID_;
            self.connectedChannel = channel;
        }
    }];
}

- (BOOL)captureOutputShouldProvideSampleAccurateRecordingStart:(nonnull AVCaptureOutput *)output { 
    // We don't require frame accurate start when we start a recording. If we answer YES, the capture output applies outputSettings immediately when the session starts previewing, resulting in higher CPU usage and shorter battery life.
    return NO;
}

#pragma mark - Output device delegate

// Credit: https://stackoverflow.com/questions/12242513/how-to-get-real-time-video-stream-from-iphone-camera-and-send-it-to-server
-(void) captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection {
    currentIndex++;
    if (connectedChannel_) {
        NSMutableData *h264Data = [[NSMutableData alloc] init];
        [self compressBuffer:sampleBuffer toData:h264Data frameIndex:currentIndex];
    }
}

-(void)sendMessageWithData:(NSData *)data {
    [connectedChannel_ sendFrameOfType:PTDesktopFrame tag:PTFrameNoTag withPayload:data callback:^(NSError *error) {
        if (error) {
            NSLog(@"Failed to send frame: %@", error);
        }
    }];
}

// https://stackoverflow.com/questions/8425012/is-there-a-practical-way-to-compress-nsdata
- (NSData *)gzipDeflate:(NSData*)data {
    if ([data length] == 0) return data;

    z_stream strm;

    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.total_out = 0;
    strm.next_in=(Bytef *)[data bytes];
    strm.avail_in = [data length];

    // Compresssion Levels:
    //   Z_NO_COMPRESSION
    //   Z_BEST_SPEED
    //   Z_BEST_COMPRESSION
    //   Z_DEFAULT_COMPRESSION

    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, (15+16), 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;

    NSMutableData *compressed = [NSMutableData dataWithLength:16384];  // 16K chunks for expansion

    do {
        if (strm.total_out >= [compressed length])
            [compressed increaseLengthBy: 16384];

        strm.next_out = [compressed mutableBytes] + strm.total_out;
        strm.avail_out = [compressed length] - strm.total_out;

        deflate(&strm, Z_FINISH);

    } while (strm.avail_out == 0);

    deflateEnd(&strm);

    [compressed setLength: strm.total_out];
    return [NSData dataWithData:compressed];
}


- (float)maximumScreenInputFramerate {
    Float64 minimumVideoFrameInterval = CMTimeGetSeconds([self.captureScreenInput minFrameDuration]);
    return minimumVideoFrameInterval > 0.0f ? 1.0f/minimumVideoFrameInterval : 0.0;
}

/* Set the screen input maximum frame rate. */
- (void)setMaximumScreenInputFramerate:(float)maximumFramerate {
    CMTime minimumFrameDuration = CMTimeMake(1, (int32_t)maximumFramerate);
    /* Set the screen input's minimum frame duration. */
    [self.captureScreenInput setMinFrameDuration:minimumFrameDuration];
}

- (BOOL)createCaptureSession {
    /* Create a capture session. */
    self.captureSession = [[AVCaptureSession alloc] init];
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        /* Specifies capture settings suitable for high quality video and audio output. */
        [self.captureSession setSessionPreset:AVCaptureSessionPreset1920x1080];
    }
    
    /* Add the main display as a capture input. */
    display = CGMainDisplayID();
    self.captureScreenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:display];
    if ([self.captureSession canAddInput:self.captureScreenInput]) {
        [self.captureSession addInput:self.captureScreenInput];
        [self setMaximumScreenInputFramerate:[self maximumScreenInputFramerate]];
    } else {
        return NO;
    }
    
    /* Add a movie file output + delegate. */
    outputDevice = [[AVCaptureVideoDataOutput alloc] init];
    [outputDevice setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    if ([self.captureSession canAddOutput:outputDevice]) {
        [self.captureSession addOutput:outputDevice];
    } else {
        return NO;
    }
    
    /* Register for notifications of errors during the capture session so we can display an alert. */
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionRuntimeErrorDidOccur:) name:AVCaptureSessionRuntimeErrorNotification object:self.captureSession];
    
    return YES;
}

- (void)captureSessionRuntimeErrorDidOccur:(NSNotification *)notification {
    NSError *error = [notification userInfo][AVCaptureSessionErrorKey];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert setMessageText:[error localizedDescription]];
    NSString *informativeText = [error localizedRecoverySuggestion];
    informativeText = informativeText ? informativeText : [error localizedFailureReason]; // No recovery suggestion, then at least tell the user why it failed.
    [alert setInformativeText:informativeText];
    
    [alert beginSheetModalForWindow:window_
                      modalDelegate:self
                     didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                        contextInfo:NULL];
}

- (void)compressBuffer:(CMSampleBufferRef)sampleBuffer toData:(NSData *)data frameIndex:(int)frameIndex {
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMVideoDimensions videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

    static VTCompressionSessionRef compressionSession;

    if (compressionSession == NULL) {
        VTCompressionSessionCreate
        (NULL,
         videoDimensions.width,
         videoDimensions.height,
         kCMVideoCodecType_H264,
         NULL,
         NULL,
         NULL,
         NULL,
         NULL,
         &compressionSession);
    }

    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    CMTime presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);

    VTCompressionSessionEncodeFrameWithOutputHandler
    (compressionSession,
     pixelBuffer,
     presentationTimestamp,
     duration,
     NULL,
     NULL,
     ^(OSStatus status,
       VTEncodeInfoFlags infoFlags,
       CMSampleBufferRef  _Nullable compressedSample) {
        [self h264ImageBuffer:compressedSample toData:data frameIndex:frameIndex];
     });

}

// Credit: https://stackoverflow.com/questions/18811917/nsdata-or-bytes-from-cmsamplebufferref
- (void) imageBuffer:(CMSampleBufferRef)source toData:(NSMutableData *)data {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(source);
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    long width = CVPixelBufferGetWidth(imageBuffer);
    long height = CVPixelBufferGetHeight(imageBuffer);
    OSType pixelBufferType = CVPixelBufferGetPixelFormatType(imageBuffer);
    void *src_buff = CVPixelBufferGetBaseAddress(imageBuffer);
    
    int widthHeightSize = sizeof(long);
    int pixelFormatSize = sizeof(UInt32);
    
    [data appendBytes:&width length:widthHeightSize];
    [data appendBytes:&height length:widthHeightSize];
    [data appendBytes:&pixelBufferType length:pixelFormatSize];
    [data appendBytes:src_buff length:bytesPerRow * height];
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
}

// https://github.com/ideawu/ios_live_streaming/blob/c7262d92c0e0f00e4dddaa8d4b745e1640f46f54/irtc/h264/VideoEncoder.m
- (void) h264ImageBuffer:(CMSampleBufferRef)sampleBuffer toData:(NSData *)data frameIndex:(int)frameIndex {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    size_t sps_size, pps_size;
    const uint8_t* sps, *pps;

    // get sps/pps without start code
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &sps_size, NULL, NULL);
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &pps_size, NULL, NULL);

    NSData *sps_data = [NSData dataWithBytes:sps length:sps_size];
    NSData *pps_data = [NSData dataWithBytes:pps length:pps_size];

    UInt8 *buf;
    size_t size;
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &size, (char **)&buf);

    // strip leading SEIs
    while(size > 0){
        uint32_t len = (buf[0]<<24) + (buf[1]<<16) + (buf[2]<<8) + buf[3];
        int type = buf[4] & 0x1f;
        if(type == 6){ // SEI
            buf += 4 + len;
            size -= 4 + len;
        }else{
            break;
        }
    }
    if(size >= 5){
        NSMutableData *finalData = [[NSMutableData alloc] init];
        [finalData appendBytes:&sps_size length:sizeof(size_t)];
        [finalData appendBytes:&pps_size length:sizeof(size_t)];
        [finalData appendBytes:sps length:sps_size];
        [finalData appendBytes:pps length:pps_size];
        [finalData appendBytes:buf length:size];

        if (frameIndex > highestIndex) {
            [self sendMessageWithData:finalData];
            highestIndex = frameIndex;
            NSLog(@"Finished frame %d", frameIndex);
        }
    }
}

@end
