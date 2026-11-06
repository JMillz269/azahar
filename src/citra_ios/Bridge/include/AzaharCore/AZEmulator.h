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

/// A request of the emulated software to type text (the 3DS software keyboard).
@interface AZKeyboardRequest : NSObject
@property(nonatomic, copy) NSString* hintText;
/// Why the previous input was rejected, shown above the field. Nil for a fresh request.
@property(nonatomic, copy, nullable) NSString* errorMessage;
/// Labels of the buttons from left to right, the last one is the one that confirms the input.
@property(nonatomic, copy) NSArray<NSString*>* buttonTexts;
/// Index of the button that confirms the input, the other ones (cancel, "I forgot") skip checks.
@property(nonatomic) NSInteger confirmButtonIndex;
@property(nonatomic) NSInteger maxLength;
@property(nonatomic) BOOL multiline;
@property(nonatomic) BOOL numeric;
/// Hands the text and the index of the pressed button to the emulated software. Returns nil when
/// the input was accepted (the request is over), otherwise why it was rejected.
@property(nonatomic, copy) NSString* _Nullable (^submit)(NSString* text, NSInteger button);
@end

/// A request of the emulated software to choose a Mii (the 3DS Mii selector).
@interface AZMiiRequest : NSObject
@property(nonatomic, copy) NSString* title;
/// Names of the Miis the player can choose from.
@property(nonatomic, copy) NSArray<NSString*>* names;
@property(nonatomic) NSInteger initialIndex;
@property(nonatomic) BOOL allowsCancel;
/// Hands the choice to the emulated software: the index of a Mii, or -1 to cancel.
@property(nonatomic, copy) void (^submit)(NSInteger index);
@end

/// A save state slot that holds a state of the running title.
@interface AZSaveStateSlot : NSObject
/// 0 is the quick slot, 1 to 10 the numbered ones.
@property(nonatomic, readonly) NSInteger slot;
@property(nonatomic, readonly) NSDate* date;
/// False when the state was made by another build and can't be loaded.
@property(nonatomic, readonly) BOOL isLoadable;
@end

/// A cheat of the running title.
@interface AZCheat : NSObject
@property(nonatomic, copy) NSString* name;
/// Gateway codes, one "XXXXXXXX XXXXXXXX" pair per line.
@property(nonatomic, copy) NSString* code;
@property(nonatomic, copy) NSString* comments;
@property(nonatomic) BOOL enabled;
@end

/// Result of loading an amiibo.
typedef NS_ENUM(NSInteger, AZAmiiboStatus) {
    AZAmiiboStatusLoaded = 0,
    AZAmiiboStatusNotRunning,
    /// The game is not asking for an amiibo right now.
    AZAmiiboStatusNotSearching,
    /// An amiibo is already on the reader.
    AZAmiiboStatusTagInUse,
    AZAmiiboStatusFailed,
};

/// Result of installing a CIA.
typedef NS_ENUM(NSInteger, AZInstallStatus) {
    AZInstallStatusSuccess = 0,
    AZInstallStatusFailedToOpen,
    AZInstallStatusNotFound,
    AZInstallStatusAborted,
    AZInstallStatusInvalid,
    AZInstallStatusEncrypted,
    AZInstallStatusUnknown,
};

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

/// Called on the main thread when the emulated software asks for text.
@property(nonatomic, copy, nullable) void (^onKeyboardRequest)(AZKeyboardRequest* request);
/// Called on the main thread when the emulated software asks for a Mii. The emulation waits until
/// the request is submitted.
@property(nonatomic, copy, nullable) void (^onMiiRequest)(AZMiiRequest* request);
/// Called on the main thread with a message for the user that is not an error stopping emulation
/// (for example a failed save state).
@property(nonatomic, copy, nullable) void (^onNotice)(NSString* title, NSString* message);

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

/// Save states, cheats, the software keyboard and CIA installation.
@interface AZEmulator (Features)

/// Registers the software keyboard and Mii selector applets. Internal, called when a title boots.
- (void)registerApplets;
/// Releases an applet the emulation thread is waiting for so it can stop. Internal.
- (void)cancelPendingApplets;

// Save states of the running title.

/// Slots that hold a state, newest first. Empty when nothing is running.
- (NSArray<AZSaveStateSlot*>*)saveStateSlots;
/// Asks the emulation to save or load a slot. Returns false when that is not possible right now.
- (BOOL)saveStateToSlot:(NSInteger)slot;
- (BOOL)loadStateFromSlot:(NSInteger)slot;

// Cheats of the running title.

- (NSArray<AZCheat*>*)cheats;
- (void)setCheatEnabled:(BOOL)enabled atIndex:(NSInteger)index;
- (void)addCheat:(AZCheat*)cheat;
- (void)replaceCheatAtIndex:(NSInteger)index with:(AZCheat*)cheat;
- (void)removeCheatAtIndex:(NSInteger)index;
/// 1-based numbers of the lines of a code that are not a valid Gateway code line.
+ (NSArray<NSNumber*>*)invalidCheatLinesInCode:(NSString*)code;

// Amiibo.

/// Puts the amiibo file on the virtual NFC reader. Changes the game makes to it are saved to the
/// file, so it should be a copy the app keeps.
- (AZAmiiboStatus)loadAmiiboAtPath:(NSString*)path;
- (void)removeAmiibo;

// Screenshot and speed.

/// Takes a screenshot at the internal resolution and saves it as a PNG in `directory`. The
/// completion block gets the path of the file, or nil when it failed, on the main thread.
- (void)takeScreenshotToDirectory:(NSString*)directory
                       completion:(void (^)(NSString* _Nullable path))completion;
/// Runs the game faster than real time (3x) while enabled.
- (void)setFastForward:(BOOL)enabled;

// CIA installation, safe to call from any thread while no title is running.

/// Installs a CIA (also its compressed form) on a background queue. `progress` and `completion`
/// are called on the main thread.
+ (void)installCIAAtPath:(NSString*)path
                progress:(void (^)(double fraction))progress
              completion:(void (^)(AZInstallStatus status))completion;

@end

NS_ASSUME_NONNULL_END
