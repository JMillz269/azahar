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
@property(nonatomic) NSInteger resolutionFactor;
@property(nonatomic) BOOL linearFiltering;
@property(nonatomic) NSInteger textureFilter;
@property(nonatomic) BOOL skipDuplicateFrames;

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
