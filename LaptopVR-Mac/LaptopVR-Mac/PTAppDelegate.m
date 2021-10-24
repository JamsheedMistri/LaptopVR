#import "PTAppDelegate.h"
#import "PTProtocol.h"

#import <peertalk/PTProtocol.h>
#import <peertalk/PTUSBHub.h>
#import <QuartzCore/QuartzCore.h>

@interface PTAppDelegate () {
    // If the remote connection is over USB transport...
    NSNumber *connectingToDeviceID_;
    NSNumber *connectedDeviceID_;
    NSDictionary *connectedDeviceProperties_;
    NSDictionary *remoteDeviceInfo_;
    dispatch_queue_t notConnectedQueue_;
    BOOL notConnectedQueueSuspended_;
    PTChannel *connectedChannel_;
    NSDictionary *consoleTextAttributes_;
    NSDictionary *consoleStatusTextAttributes_;
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

@implementation PTAppDelegate
{
    CGDirectDisplayID display;
    AVCaptureVideoDataOutput *outputDevice;
    NSMutableArray *shadeWindows;
    BOOL isCurrentlyStreaming;
}

@synthesize window = window_;
@synthesize connectedDeviceID = connectedDeviceID_;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // We use a serial queue that we toggle depending on if we are connected or
    // not. When we are not connected to a peer, the queue is running to handle
    // "connect" tries. When we are connected to a peer, the queue is suspended
    // thus no longer trying to connect.
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
    if (   type != PTExampleFrameTypeDeviceInfo
        && type != PTFrameTypeEndOfStream) {
        NSLog(@"Unexpected frame of type %u", type);
        [channel close];
        return NO;
    } else {
        return YES;
    }
}

- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
    if (type == PTExampleFrameTypeDeviceInfo) {
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
    channel.userInfo = [NSString stringWithFormat:@"127.0.0.1:%d", PTExampleProtocolIPv4PortNumber];
    [channel connectToPort:PTExampleProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, PTAddress *address) {
        if (error) {
            if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
                // this is an expected state
            } else {
                NSLog(@"Failed to connect to 127.0.0.1:%d: %@", PTExampleProtocolIPv4PortNumber, error);
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
    
    [channel connectToPort:PTExampleProtocolIPv4PortNumber overUSBHub:PTUSBHub.sharedHub deviceID:connectingToDeviceID_ callback:^(NSError *error) {
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
    // We don't require frame accurate start when we start a recording. If we answer YES, the capture output
    // applies outputSettings immediately when the session starts previewing, resulting in higher CPU usage
    // and shorter battery life.
    return NO;
}

#pragma mark - Output device delegate

// Credit: https://stackoverflow.com/questions/12242513/how-to-get-real-time-video-stream-from-iphone-camera-and-send-it-to-server
-(void) captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection
{
    if (connectedChannel_) {
        NSMutableData *data = [[NSMutableData alloc] init];
        [self imageBuffer:sampleBuffer toData:data];
        [connectedChannel_ sendFrameOfType:PTDesktopFrame tag:PTFrameNoTag withPayload:data callback:^(NSError *error) {
            if (error) {
                NSLog(@"Failed to send frame: %@", error);
            }
        }];
    }
}

- (float)maximumScreenInputFramerate
{
    Float64 minimumVideoFrameInterval = CMTimeGetSeconds([self.captureScreenInput minFrameDuration]);
    return minimumVideoFrameInterval > 0.0f ? 1.0f/minimumVideoFrameInterval : 0.0;
}

/* Set the screen input maximum frame rate. */
- (void)setMaximumScreenInputFramerate:(float)maximumFramerate
{
    CMTime minimumFrameDuration = CMTimeMake(1, (int32_t)maximumFramerate);
    /* Set the screen input's minimum frame duration. */
    [self.captureScreenInput setMinFrameDuration:minimumFrameDuration];
}

- (BOOL)createCaptureSession
{
    /* Create a capture session. */
    self.captureSession = [[AVCaptureSession alloc] init];
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720])
    {
        /* Specifies capture settings suitable for high quality video and audio output. */
        [self.captureSession setSessionPreset:AVCaptureSessionPreset1280x720];
    }
    
    /* Add the main display as a capture input. */
    display = CGMainDisplayID();
    self.captureScreenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:display];
    if ([self.captureSession canAddInput:self.captureScreenInput])
    {
        [self.captureSession addInput:self.captureScreenInput];
        [self setMaximumScreenInputFramerate:[self maximumScreenInputFramerate] / 10];
    }
    else
    {
        return NO;
    }
    
    /* Add a movie file output + delegate. */
    outputDevice = [[AVCaptureVideoDataOutput alloc] init];
    [outputDevice setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    if ([self.captureSession canAddOutput:outputDevice])
    {
        [self.captureSession addOutput:outputDevice];
    }
    else
    {
        return NO;
    }
    
    /* Register for notifications of errors during the capture session so we can display an alert. */
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionRuntimeErrorDidOccur:) name:AVCaptureSessionRuntimeErrorNotification object:self.captureSession];
    
    return YES;
}

- (void)captureSessionRuntimeErrorDidOccur:(NSNotification *)notification
{
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

// Credit: https://stackoverflow.com/questions/18811917/nsdata-or-bytes-from-cmsamplebufferref
- (void) imageBuffer:(CMSampleBufferRef)source toData:(NSMutableData *)data {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(source);
    CVPixelBufferLockBaseAddress(imageBuffer,0);
    
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    long width = CVPixelBufferGetWidth(imageBuffer);
    long height = CVPixelBufferGetHeight(imageBuffer);
    OSType pixelBufferType = CVPixelBufferGetPixelFormatType(imageBuffer);
    void *src_buff = CVPixelBufferGetBaseAddress(imageBuffer);
    
    [data appendBytes:&width length:sizeof(long)];
    [data appendBytes:&height length:sizeof(long)];
    [data appendBytes:&pixelBufferType length:sizeof(UInt32)];
    [data appendBytes:src_buff length:bytesPerRow * height];
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
}

@end
