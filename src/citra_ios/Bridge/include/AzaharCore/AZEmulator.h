// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

@class AZConfiguration;

NS_ASSUME_NONNULL_BEGIN

/// 3DS buttons. The values match Settings::NativeButton.
typedef NS_ENUM(NSInteger, AZButton) {
    AZButtonA = 0,
    AZButtonB = 1,
    AZButtonX = 2,
    AZButtonY = 3,
    AZButtonUp = 4,
    AZButtonDown = 5,
    AZButtonLeft = 6,
    AZButtonRight = 7,
    AZButtonL = 8,
    AZButtonR = 9,
    AZButtonStart = 10,
    AZButtonSelect = 11,
    AZButtonDebug = 12,
    AZButtonGPIO14 = 13,
    AZButtonZL = 14,
    AZButtonZR = 15,
    AZButtonHome = 16,
    AZButtonPower = 17,
};

/// 3DS analog sticks. The values match Settings::NativeAnalog.
typedef NS_ENUM(NSInteger, AZAnalog) {
    AZAnalogCirclePad = 0,
    AZAnalogCStick = 1,
};

typedef NS_ENUM(NSInteger, AZEmulationState) {
    AZEmulationStateStopped = 0,
    AZEmulationStateRunning = 1,
    AZEmulationStatePaused = 2,
};

/// Error domain of the errors reported by AZEmulator.
extern NSErrorDomain const AZEmulatorErrorDomain;

/// Owns the emulated 3DS. All methods must be called from the main thread unless stated
/// otherwise; emulation itself runs on a dedicated thread.
@interface AZEmulator : NSObject

@property(class, nonatomic, readonly) AZEmulator* shared;

/// True when the process can generate code at runtime (a debugger enabled JIT).
@property(class, nonatomic, readonly) BOOL isJITAvailable;

/// True when MetalFX upscaling can be used on this device.
@property(class, nonatomic, readonly) BOOL isUpscalingSupported;

/// Version string of the emulator core.
@property(class, nonatomic, readonly) NSString* versionString;

/// Directory holding the emulator user data (sdmc, nand, config, cache...).
@property(nonatomic, readonly) NSString* userDirectory;

@property(nonatomic, readonly) AZEmulationState state;

/// Speed and frame statistics, safe to read from any thread.
@property(nonatomic, readonly) double emulationSpeed;
@property(nonatomic, readonly) double framesPerSecond;
/// Progress (0 to 1) of building the cached shaders while a game boots, negative otherwise.
@property(nonatomic, readonly) double shaderBuildProgress;
/// Average GPU time, time the emulation thread waited for the GPU, and draw calls per frame.
@property(nonatomic, readonly) double gpuMilliseconds;
@property(nonatomic, readonly) double stallMilliseconds;
@property(nonatomic, readonly) double drawsPerFrame;

/// Called on the main thread when emulation stops on its own (shutdown or error). The error is
/// nil on a regular shutdown.
@property(nonatomic, copy, nullable) void (^onStopped)(NSError* _Nullable error);

- (instancetype)init NS_UNAVAILABLE;

/// Prepares the emulator user directory and logging. Must be called once at startup.
- (void)setUpWithUserDirectory:(NSString*)directory NS_SWIFT_NAME(setUp(userDirectory:));

/// Applies a configuration. Settings that can't change while running take effect on next boot.
- (void)applyConfiguration:(AZConfiguration*)configuration NS_SWIFT_NAME(apply(configuration:));

/// Sets the Metal layer emulation is presented to and its drawable size in pixels.
- (void)setRenderLayer:(nullable CAMetalLayer*)layer NS_SWIFT_NAME(setRenderLayer(_:));
- (void)setDrawableSize:(CGSize)size
               portrait:(BOOL)portrait NS_SWIFT_NAME(setDrawableSize(_:portrait:));

/// Starts emulating the title at the provided path.
- (BOOL)startWithPath:(NSString*)path error:(NSError**)error NS_SWIFT_NAME(start(path:));
- (void)pause;
- (void)resume;
/// Stops emulation and waits for the emulation thread to exit.
- (void)stop;

// Input, safe to call from any thread.
- (void)setButton:(AZButton)button pressed:(BOOL)pressed NS_SWIFT_NAME(setButton(_:pressed:));
/// Values are in the [-1, 1] range, +Y is up.
- (void)setAnalog:(AZAnalog)analog x:(float)x y:(float)y NS_SWIFT_NAME(setAnalog(_:x:y:));
/// Touch positions are in drawable pixels.
- (void)touchBeganAtPoint:(CGPoint)point NS_SWIFT_NAME(touchBegan(at:));
- (void)touchMovedToPoint:(CGPoint)point NS_SWIFT_NAME(touchMoved(to:));
- (void)touchEnded;
/// Accelerometer in g and gyroscope in degrees per second, in 3DS axes.
- (void)setMotionAccelerationX:(float)ax
                             y:(float)ay
                             z:(float)az
                         gyroX:(float)gx
                         gyroY:(float)gy
                         gyroZ:(float)gz
    NS_SWIFT_NAME(setMotion(accelX:accelY:accelZ:gyroX:gyroY:gyroZ:));

@end

NS_ASSUME_NONNULL_END
