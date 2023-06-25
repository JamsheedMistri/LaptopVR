//
//  StreamLayerViewController.m
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/16/22.
//

#import "StreamLayerViewController.h"

@implementation StreamLayerViewController {
    AVSampleBufferDisplayLayer *videoLayer;
    UIView *subview;
    int width;
    int height;
}

- (void)viewDidLoad {
    videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    subview = [[UIView alloc] init];
    subview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subview];
    [subview.layer addSublayer:videoLayer];
    [subview.leftAnchor constraintEqualToAnchor:self.view.leftAnchor].active = YES;
    [subview.rightAnchor constraintEqualToAnchor:self.view.rightAnchor].active = YES;
    [subview.topAnchor constraintEqualToAnchor:self.view.topAnchor].active = YES;
    [subview.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [videoLayer enqueueSampleBuffer:sampleBuffer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    videoLayer.frame = subview.bounds;
}

- (void)updateFrameWidth:(int)frameWidth height:(int)frameHeight {
    // Set the width of the frame to the full width of the video; the unviewable parts are clipped by the superview
    CGRect frame = subview.bounds;
    frame.size.width = (((float)frameWidth / (float)frameHeight) * (float)frame.size.height);
    videoLayer.frame = frame;
    
    width = frameWidth;
    height = frameHeight;
}

- (void)updatePitch:(float)pitch andRoll:(float)roll forMotionManager:(MotionManager*)motionManager{
    float SENSITIVITY = 12;
    
    pitch *= SENSITIVITY;
    roll *= SENSITIVITY;
    
    if (pitch > M_PI / 2) {
        pitch = M_PI / 2;
        [motionManager updateReferenceFrame];
    } else if (pitch < -M_PI / 2) {
        pitch = -M_PI / 2;
        [motionManager updateReferenceFrame];
    }
    
    if (roll > M_PI / 2) {
        roll = M_PI / 2;
        [motionManager updateReferenceFrame];
    } else if (roll < -M_PI / 2) {
        roll = -M_PI / 2;
        [motionManager updateReferenceFrame];
    }
    
    // Scale factor of how far we're looking left or right, -1 is leftmost and +1 is rightmost
    float pitchScaleFactor = pitch / (M_PI / 2);
    int maximumPitchDeltaFromCenter = (videoLayer.frame.size.width - subview.bounds.size.width);
    int pitchDeltaFromCenter = pitchScaleFactor * maximumPitchDeltaFromCenter;
    
    float rollScaleFactor = roll / (M_PI / 2);
    int maximumRollDeltaFromCenter = videoLayer.frame.size.height / 2;
    
    CGRect frame = videoLayer.frame;
    frame.origin.x = pitchDeltaFromCenter - (maximumPitchDeltaFromCenter / 2);
    frame.origin.y = -(rollScaleFactor * maximumRollDeltaFromCenter);
    videoLayer.frame = frame;
}

@end
