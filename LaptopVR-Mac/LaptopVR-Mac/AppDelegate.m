#import "AppDelegate.h"
#import "PTProtocol.h"
#import <peertalk/PTProtocol.h>
#import <peertalk/PTUSBHub.h>
#import <VideoToolbox/VideoToolbox.h>
#import "H264Packet.h"

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
}

@property (readonly) NSNumber *connectedDeviceID;
@property PTChannel *connectedChannel;
@property (weak) IBOutlet NSTextField *infoLabel;
@property (weak) IBOutlet NSButton *startButton;

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
    VTCompressionSessionRef compressionSession;
}

@synthesize window = window_;
@synthesize connectedDeviceID = connectedDeviceID_;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    notConnectedQueue_ = dispatch_queue_create("PTExample.notConnectedQueue", DISPATCH_QUEUE_SERIAL);
    isCurrentlyStreaming = false;
    
    // Start listening for device attached/detached notifications
    [self startListeningForDevices];
    
    // Start trying to connect to local IPv4 port
    [self enqueueConnectToLocalIPv4Port];
    
    NSLog(@"Ready for action — connecting at will.");
}

- (IBAction)toggleStreamModeButtonClicked:(id)sender {
    if (isCurrentlyStreaming) [self stopStream];
    else [self startStream];
}

- (void)startStream {
    // Set up AVCaptureSession, VTCompressionSession, and UI
    [self createCaptureSession];
    [self setupVTCompressionSession];
    [self.captureSession startRunning];
    [_startButton setTitle:@"Stop LaptopVR"];
    isCurrentlyStreaming = true;
}

- (void)stopStream {
    // Clean up AVCaptureSession, VTCompressionSession, and UI
    [self.captureSession stopRunning];
    [self cleanupVTCompressionSession];
    [_startButton setTitle:@"Start LaptopVR"];
    isCurrentlyStreaming = false;
}

#pragma mark - PTChannelDelegate

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
    // If we received device info, update UI accordingly (device connected)
    if (type == PTDeviceInfo) {
        NSDictionary *deviceInfo = [NSData dictionaryWithContentsOfData:payload];
        NSString *deviceName = [deviceInfo valueForKey:@"name"];
        NSLog(@"Connected to %@", deviceName);
        [_startButton setEnabled:true];
        _infoLabel.stringValue = [NSString stringWithFormat:@"Connected to %@", deviceName];
        [_startButton setTitle:@"Start LaptopVR"];
        isCurrentlyStreaming = false;
    }
}

- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    // Channel disconnected, update UI accordingly
    if (connectedDeviceID_ && [connectedDeviceID_ isEqualToNumber:channel.userInfo]) {
        [self didDisconnectFromDevice:connectedDeviceID_];
    }
    
    if (connectedChannel_ == channel) {
        NSLog(@"Disconnected from %@", channel.userInfo);
        if (isCurrentlyStreaming) {
            [self stopStream];
        }
        [_startButton setEnabled:false];
        _infoLabel.stringValue = @"Waiting for device to connect...";
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

#pragma mark - AVCaptureSession delegate

- (BOOL)captureOutputShouldProvideSampleAccurateRecordingStart:(nonnull AVCaptureOutput *)output { 
    return NO;
}

-(void) captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection {
    if (connectedChannel_) [self enqueueBuffer:sampleBuffer];
}

-(void)sendMessageWithData:(NSData *)data {
    [connectedChannel_ sendFrameOfType:PTDesktopFrame tag:PTFrameNoTag withPayload:data callback:^(NSError *error) {
        if (error) NSLog(@"Failed to send frame: %@", error);
    }];
}

- (float)maximumScreenInputFramerate {
    Float64 minimumVideoFrameInterval = CMTimeGetSeconds([self.captureScreenInput minFrameDuration]);
    return minimumVideoFrameInterval > 0.0f ? 1.0f/minimumVideoFrameInterval : 0.0;
}

- (void)setMaximumScreenInputFramerate:(float)maximumFramerate {
    // Set the screen input maximum frame rate
    CMTime minimumFrameDuration = CMTimeMake(1, (int32_t)maximumFramerate);
    [self.captureScreenInput setMinFrameDuration:minimumFrameDuration];
}

- (BOOL)createCaptureSession {
    // Create a capture session
    self.captureSession = [[AVCaptureSession alloc] init];
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        [self.captureSession setSessionPreset:AVCaptureSessionPreset1920x1080];
    }
    
    // Add the main display as a capture input
    display = CGMainDisplayID();
    self.captureScreenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:display];
    if ([self.captureSession canAddInput:self.captureScreenInput]) {
        [self.captureSession addInput:self.captureScreenInput];
        [self setMaximumScreenInputFramerate:[self maximumScreenInputFramerate]];
    } else {
        return NO;
    }
    
    // Set output device to our delegate
    outputDevice = [[AVCaptureVideoDataOutput alloc] init];
    [outputDevice setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    if ([self.captureSession canAddOutput:outputDevice]) {
        [self.captureSession addOutput:outputDevice];
    } else {
        return NO;
    }
    
    // Register for notifications of errors during the capture session so we can log them
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionRuntimeErrorDidOccur:) name:AVCaptureSessionRuntimeErrorNotification object:self.captureSession];
    
    return YES;
}

- (void)captureSessionRuntimeErrorDidOccur:(NSNotification *)notification {
    NSError *error = [notification userInfo][AVCaptureSessionErrorKey];
    NSLog(@"Error: %@ ", [error userInfo]);
}

#pragma mark - VideoToolbox encoder

- (void)setupVTCompressionSession {
    NSDictionary<NSString *, id> * encoderSpecification = @{
        (NSString *) kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
        (NSString *) kVTCompressionPropertyKey_RealTime: @YES,
        (NSString *) kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: @YES,
        (NSString *) kVTCompressionPropertyKey_AllowFrameReordering: @NO,
        (NSString *) kVTCompressionPropertyKey_ExpectedFrameRate: @15,
    };
    
    if (@available(macOS 12.1, *)) {
        encoderSpecification = @{
            (NSString *) kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
            (NSString *) kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
            (NSString *) kVTCompressionPropertyKey_RealTime: @YES,
            (NSString *) kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: @YES,
            (NSString *) kVTCompressionPropertyKey_AllowFrameReordering: @NO,
            (NSString *) kVTCompressionPropertyKey_ExpectedFrameRate: @15,
        };
    }
    
    if (compressionSession == NULL) {
        dispatch_queue_t setupVTCompressionSessionQueue = dispatch_queue_create([@"setupVTCompressionSession" UTF8String], nil);
        dispatch_async(setupVTCompressionSessionQueue, ^{
            VTCompressionSessionCreate
            (NULL,
             1920,
             1080,
             kCMVideoCodecType_H264,
             (__bridge CFDictionaryRef) encoderSpecification,
             NULL,
             NULL,
             compressionOutputCallback,
             (__bridge void * _Nullable)(self),
             &(self->compressionSession));
        });
    }
}

- (void)cleanupVTCompressionSession {
    if (compressionSession) {
        VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid);
        VTCompressionSessionInvalidate(compressionSession);
        CFRelease(compressionSession);
        compressionSession = NULL;
    }
}

- (void)enqueueBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    CMTime presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    
    VTCompressionSessionEncodeFrame
    (compressionSession,
     pixelBuffer,
     presentationTimestamp,
     duration,
     NULL,
     NULL,
     NULL);
}

static void compressionOutputCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    AppDelegate *weakSelf = (__bridge AppDelegate *)outputCallbackRefCon;
    // Send H264 encoded frame for serialization and sending
    if (status == noErr) return [weakSelf sendH264SampleBuffer:sampleBuffer];
}

#pragma mark - VideoToolbox -> PeerTalk bridge

- (void)sendH264SampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    
    // Serialize H264 compressed frame
    NSData *packet = [H264Packet sampleBufferToH264Packet:sampleBuffer];
    
    // Send to PeerTalk
    [self sendMessageWithData:packet];
}

@end
