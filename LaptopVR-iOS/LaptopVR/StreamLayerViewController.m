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
    
//    frame.origin.x -= 100;
    
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

- (void)updatePitch:(float)pitch {
    float SENSITIVITY = 12;
    
    pitch *= SENSITIVITY;
    if (pitch > M_PI / 2) {
        pitch = M_PI / 2;
    } else if (pitch < -M_PI / 2) {
        pitch = -M_PI / 2;
    }
    
    // Scale factor of how far we're looking left or right, -1 is leftmost and +1 is rightmost
    float scaleFactor = pitch / (M_PI / 2);
    int maximumDeltaFromCenter = (videoLayer.frame.size.width - subview.bounds.size.width) / 2;
    int deltaFromCenter = scaleFactor * maximumDeltaFromCenter;
    
    CGRect frame = videoLayer.frame;
    frame.origin.x = -(maximumDeltaFromCenter - deltaFromCenter);
    videoLayer.frame = frame;
}

@end
