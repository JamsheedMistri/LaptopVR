//
//  StreamLayerViewController.m
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/16/22.
//

#import "StreamLayerViewController.h"

@implementation StreamLayerViewController {
    AVSampleBufferDisplayLayer *videoLayer;
}

- (void)viewDidLoad {
    videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:videoLayer];
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [videoLayer enqueueSampleBuffer:sampleBuffer];
}

- (void)updateFrame {
    videoLayer.frame = self.view.frame;
}

@end
