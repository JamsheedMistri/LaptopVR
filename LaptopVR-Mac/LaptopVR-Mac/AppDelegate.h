#import <Cocoa/Cocoa.h>
#import <peertalk/PTChannel.h>
#import <AVFoundation/AVFoundation.h>

static const NSTimeInterval PTAppReconnectDelay = 1.0;

@interface AppDelegate : NSObject <NSApplicationDelegate, PTChannelDelegate, AVCaptureFileOutputDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property (assign) IBOutlet NSWindow *window;

@property (strong) AVCaptureSession *captureSession;
@property (strong) AVCaptureScreenInput *captureScreenInput;

@end
