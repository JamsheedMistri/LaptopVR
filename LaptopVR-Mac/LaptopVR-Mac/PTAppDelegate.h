#import <Cocoa/Cocoa.h>

#import <peertalk/PTChannel.h>
#import <AVFoundation/AVFoundation.h>

static const NSTimeInterval PTAppReconnectDelay = 1.0;

@interface PTAppDelegate : NSObject <NSApplicationDelegate, PTChannelDelegate, AVCaptureFileOutputDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet NSTextView *outputTextView;

@property (strong) AVCaptureSession *captureSession;
@property (strong) AVCaptureScreenInput *captureScreenInput;

@end
