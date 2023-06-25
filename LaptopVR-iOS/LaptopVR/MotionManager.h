//
//  MotionManager.h
//  LaptopVR
//
//  Created by Jamsheed Mistri on 1/17/22.
//

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>

@interface MotionManager : NSObject

@property (strong) CMMotionManager *motionManager;
@property (strong) CMAttitude *referenceAttitude;

- (void)enableMotion;
- (void)updateAttitudeAndGetPitch:(float *)pitch andRoll:(float *)roll;
- (void)updateReferenceFrame;

@end
