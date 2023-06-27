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
    self.pitchOrigin = 0;
    self.rollOrigin = 0;
}

- (void)processMotionUpdatesAndReturnPitchScaleFactor:(float *)pitchScaleFactor
                                   andRollScaleFactor:(float *)rollScaleFactor {
    if (self.referenceAttitude == nil) {
        self.referenceAttitude = self.motionManager.deviceMotion.attitude;
        self.pitchOrigin = self.referenceAttitude.pitch;
        self.rollOrigin = self.referenceAttitude.roll;
    }

    CMAttitude *attitude = self.motionManager.deviceMotion.attitude;
    [attitude multiplyByInverseOfAttitude:self.referenceAttitude];
    
    float SENSITIVITY = 11;
        
    float pitchDelta = attitude.pitch - self.pitchOrigin;
    float rollDelta = attitude.roll - self.rollOrigin;
        
    float maxPitchWithSensitivity = M_PI / SENSITIVITY;
    float maxRollWithSensitivity = M_PI / SENSITIVITY;
    
    if (pitchDelta > maxPitchWithSensitivity) {
        [self updateReferenceFrame];
        self.pitchOrigin = -maxPitchWithSensitivity;
        self.rollOrigin = -rollDelta;
        pitchDelta = maxPitchWithSensitivity;
    } else if (pitchDelta < -maxPitchWithSensitivity) {
        [self updateReferenceFrame];
        self.pitchOrigin = maxPitchWithSensitivity;
        self.rollOrigin = -rollDelta;
        pitchDelta = -maxPitchWithSensitivity;
    }

    if (rollDelta > maxRollWithSensitivity) {
        [self updateReferenceFrame];
        self.rollOrigin = -maxRollWithSensitivity;
        self.pitchOrigin = -pitchDelta;
        rollDelta = maxRollWithSensitivity;
    } else if (rollDelta < -maxRollWithSensitivity) {
        [self updateReferenceFrame];
        self.rollOrigin = maxRollWithSensitivity;
        self.pitchOrigin = -pitchDelta;
        rollDelta = -maxRollWithSensitivity;
    }
    
    // Scale factor of how far we're looking left or right, -1 is leftmost and +1 is rightmost
    *pitchScaleFactor = pitchDelta / maxPitchWithSensitivity;
    *rollScaleFactor = rollDelta / maxRollWithSensitivity;
}

- (void)updateReferenceFrame {
    self.referenceAttitude = self.motionManager.deviceMotion.attitude;
}

@end
