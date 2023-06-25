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

- (void)updateAttitudeAndGetPitch:(float *)pitch andRoll:(float *)roll {
    if (self.referenceAttitude == nil) {
        self.referenceAttitude = self.motionManager.deviceMotion.attitude;
    }

    CMAttitude *attitude = self.motionManager.deviceMotion.attitude;
    [attitude multiplyByInverseOfAttitude:self.referenceAttitude];
    
    *pitch = attitude.pitch;
    *roll = attitude.roll;
}

- (void)updateReferenceFrame {
    self.referenceAttitude = self.motionManager.deviceMotion.attitude;
}


@end
