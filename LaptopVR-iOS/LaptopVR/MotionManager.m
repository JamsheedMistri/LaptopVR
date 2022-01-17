//
//  MotionManager.m
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/17/22.
//

#import "MotionManager.h"

@implementation MotionManager

- (void)enableMotion {
    self.motionManager = [[CMMotionManager alloc] init];
    self.referenceAttitude = nil;
    [self.motionManager startDeviceMotionUpdates];
}

- (float)updateAttitudeAndGetPitch {
    if (self.referenceAttitude == nil) {
        self.referenceAttitude = self.motionManager.deviceMotion.attitude;
    }

    CMAttitude *attitude = self.motionManager.deviceMotion.attitude;
    [attitude multiplyByInverseOfAttitude:self.referenceAttitude];

    return attitude.pitch;
}


@end
