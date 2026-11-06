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
};

/// Screen layouts, matching Settings::PortraitLayoutOption.
typedef NS_ENUM(NSInteger, AZPortraitLayoutOption) {
    AZPortraitLayoutOptionTopFullWidth = 0,
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

// Audio
@property(nonatomic) BOOL audioStretching;
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
