// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Screen layouts, matching Settings::LayoutOption (landscape).
typedef NS_ENUM(NSInteger, AZLayoutOption) {
    AZLayoutOptionDefault = 0,
    AZLayoutOptionSingleScreen = 1,
    AZLayoutOptionLargeScreen = 2,
    AZLayoutOptionSideScreen = 3,
    AZLayoutOptionHybridScreen = 5,
    AZLayoutOptionCustom = 6,
};

/// Screen layouts, matching Settings::PortraitLayoutOption.
typedef NS_ENUM(NSInteger, AZPortraitLayoutOption) {
    AZPortraitLayoutOptionTopFullWidth = 0,
    AZPortraitLayoutOptionCustom = 1,
    AZPortraitLayoutOptionOriginal = 2,
};

/// Subset of the emulator settings exposed to the iOS frontend. The app persists these and hands
/// them to the core before starting emulation.
@interface AZConfiguration : NSObject

// CPU
@property(nonatomic) BOOL useCPUJIT;
@property(nonatomic) NSInteger cpuClockPercentage;

// Graphics
@property(nonatomic) BOOL useShaderJIT;
@property(nonatomic) BOOL useHardwareShaders;
@property(nonatomic) BOOL accurateMultiplication;
@property(nonatomic) NSInteger resolutionFactor;
@property(nonatomic) BOOL linearFiltering;
@property(nonatomic) NSInteger textureFilter;
/// 0: off, 1: MetalFX spatial upscaling.
@property(nonatomic) NSInteger upscaling;
@property(nonatomic) BOOL skipDuplicateFrames;
@property(nonatomic) BOOL asyncShaderCompilation;
/// Fragment lighting in half precision with fast normalization (applies to the next game).
@property(nonatomic) BOOL fastLighting;
/// Texture combiners in half precision (applies to the next game).
@property(nonatomic) BOOL fastColor;
/// Depth mapped in the vertex shader so the GPU's hidden surface removal works (next game).
@property(nonatomic) BOOL hiddenSurfaceRemoval;
/// GPU memory compression of textures: 0 off, 1 lossless, 2 lossy (next game).
@property(nonatomic) NSInteger textureCompression;
/// Small depth reads by the game get the previous frame's values instead of waiting (next game).
@property(nonatomic) BOOL fastDepthReadback;
/// Holds each frame on screen for the time of a game frame so frames are evenly spaced.
@property(nonatomic) BOOL framePacing;
@property(nonatomic) BOOL fastShaderMath;
/// Settings::StereoRenderOption: 0 off, 1 side by side, 3 anaglyph, 4 interlaced, 5 reverse.
@property(nonatomic) NSInteger stereoMode;
/// Device cameras behind the 3DS cameras: 0 none, 1 back camera, 2 front camera.
@property(nonatomic) NSInteger outerCamera;
@property(nonatomic) NSInteger innerCamera;
/// Strength of the 3D effect in percent.
@property(nonatomic) NSInteger stereoDepth;
@property(nonatomic) BOOL swapEyes3D;
@property(nonatomic) NSInteger anisotropy;
@property(nonatomic) BOOL diskShaderCache;

// Layout
@property(nonatomic) AZLayoutOption layoutOption;
@property(nonatomic) AZPortraitLayoutOption portraitLayoutOption;
@property(nonatomic) BOOL swapScreens;
@property(nonatomic) BOOL uprightScreens;
/// Pixels between the screens of the layouts that have a gap.
@property(nonatomic) NSInteger screenGap;
/// How many times larger the large screen is than the small one (1 to 16).
@property(nonatomic) float largeScreenProportion;
/// Settings::SmallScreenPosition: 0 top right, 1 middle right, 2 bottom right, 3 top left,
/// 4 middle left, 5 bottom left, 6 above the large screen, 7 below it.
@property(nonatomic) NSInteger smallScreenPosition;
/// Rectangles of the custom layouts as fractions of the screen: top x, y, width, height, then the
/// same for the bottom screen. Empty to use the default.
@property(nonatomic, copy) NSArray<NSNumber*>* customLayoutLandscape;
@property(nonatomic, copy) NSArray<NSNumber*>* customLayoutPortrait;
/// Opacity of the second screen of the custom landscape layout, in percent.
@property(nonatomic) NSInteger customSecondLayerOpacity;

/// Show the top screen on an external display (AirPlay, HDMI) and the touch screen on the device.
@property(nonatomic) BOOL useExternalDisplay;

// Textures
@property(nonatomic) BOOL customTextures;
@property(nonatomic) BOOL preloadTextures;
@property(nonatomic) BOOL dumpTextures;

// Audio
@property(nonatomic) BOOL audioStretching;
/// Plays the audio at full speed while the emulation runs slower (can desync the audio).
@property(nonatomic) BOOL realtimeAudio;
/// Feeds the device microphone to the emulated console's microphone.
@property(nonatomic) BOOL useMicrophone;
@property(nonatomic) float volume;

// Post-processing
/// 0 none, 1 sharpen, 2 LCD grid, 3 scanlines.
@property(nonatomic) NSInteger postEffect;
/// 0 Dubois, 1 gray, 2 half color, 3 color.
@property(nonatomic) NSInteger anaglyphMode;
/// The name of a Metal shader file in Azahar/shaders/post (without .metal), or empty.
@property(nonatomic, copy) NSString* postShader;

// Storage
/// Keep the console's SD card on the device (on by default).
@property(nonatomic) BOOL useVirtualSD;
/// Store installed CIAs compressed.
@property(nonatomic) BOOL compressCIAInstalls;
/// A folder for the nand and the virtual SD card (as the subfolders nand and sdmc) instead of the
/// Azahar folder, or nil.
@property(nonatomic, copy, nullable) NSString* customStoragePath;

// Extras
@property(nonatomic) BOOL fixedClock;
@property(nonatomic) NSInteger fixedTime;
@property(nonatomic) BOOL fixedBattery;
@property(nonatomic) NSInteger batteryLevel;
@property(nonatomic) BOOL batteryCharging;
@property(nonatomic) NSInteger stepsPerHour;
@property(nonatomic) BOOL regionFreePatch;
@property(nonatomic) BOOL pluginLoader;
@property(nonatomic) BOOL onlineModules;
@property(nonatomic) NSInteger aspectRatio;
@property(nonatomic) BOOL topStretch;
@property(nonatomic) BOOL bottomStretch;
@property(nonatomic) NSInteger topPaddingH;
@property(nonatomic) NSInteger topPaddingV;
@property(nonatomic) NSInteger bottomPaddingH;
@property(nonatomic) NSInteger bottomPaddingV;
@property(nonatomic) NSInteger cardboardSize;
@property(nonatomic) NSInteger cardboardXShift;
@property(nonatomic) NSInteger cardboardYShift;
@property(nonatomic) NSInteger fastForwardSpeed;
@property(nonatomic) BOOL fastForwardHold;

// System
@property(nonatomic) BOOL isNew3DS;
/// -1 = auto select, 0 = Japan, 1 = USA, 2 = Europe, 3 = Australia, 4 = China, 5 = Korea,
/// 6 = Taiwan
@property(nonatomic) NSInteger region;
@property(nonatomic) BOOL useFrameLimit;
@property(nonatomic) NSInteger frameLimit;

/// Default configuration.
+ (instancetype)defaultConfiguration NS_SWIFT_NAME(makeDefault());

@end

NS_ASSUME_NONNULL_END
