//
//  StreamLayerViewController.h
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/16/22.
//

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface StreamLayerViewController : UIViewController

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)updateFrame;

@end

NS_ASSUME_NONNULL_END
