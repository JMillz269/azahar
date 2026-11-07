// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AzaharCore/AZConfiguration.h>

@implementation AZConfiguration

+ (instancetype)defaultConfiguration {
    AZConfiguration* config = [[AZConfiguration alloc] init];
    config.useCPUJIT = YES;
    config.cpuClockPercentage = 100;
    config.useShaderJIT = YES;
    config.useHardwareShaders = YES;
    config.accurateMultiplication = YES;
    config.resolutionFactor = 1;
    config.linearFiltering = YES;
    config.textureFilter = 0;
    config.upscaling = 0;
    config.skipDuplicateFrames = NO;
    config.asyncShaderCompilation = YES;
    config.framePacing = YES;
    config.fastShaderMath = NO;
    config.fastLighting = NO;
    config.stereoMode = 0;
    config.outerCamera = 0;
    config.innerCamera = 0;
    config.stereoDepth = 50;
    config.swapEyes3D = NO;
    config.anisotropy = 4;
    config.diskShaderCache = YES;
    config.layoutOption = AZLayoutOptionDefault;
    config.portraitLayoutOption = AZPortraitLayoutOptionTopFullWidth;
    config.screenGap = 0;
    config.largeScreenProportion = 4.0f;
    config.smallScreenPosition = 2;
    config.customLayoutLandscape = @[];
    config.customLayoutPortrait = @[];
    config.customSecondLayerOpacity = 100;
    config.useExternalDisplay = YES;
    config.customTextures = NO;
    config.preloadTextures = NO;
    config.dumpTextures = NO;
    config.swapScreens = NO;
    config.uprightScreens = NO;
    config.audioStretching = YES;
    config.volume = 1.0f;
    config.isNew3DS = YES;
    config.region = -1;
    config.useFrameLimit = YES;
    config.frameLimit = 100;
    return config;
}

@end
