//
//  StreamLayerViewController.h
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/16/22.
//

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import "MotionManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface StreamLayerViewController : UIViewController

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)updateFrameWidth:(int)width height:(int)height;
- (void)updatePitch:(float)pitch andRoll:(float)roll forMotionManager:(MotionManager *)motionManager;

@end

NS_ASSUME_NONNULL_END
