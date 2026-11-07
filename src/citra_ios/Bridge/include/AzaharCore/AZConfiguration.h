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
/// Feeds the device microphone to the emulated console's microphone.
@property(nonatomic) BOOL useMicrophone;
@property(nonatomic) float volume;

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
