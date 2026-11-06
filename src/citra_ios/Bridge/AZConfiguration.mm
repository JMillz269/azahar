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
    config.fastShaderMath = NO;
    config.stereoMode = 0;
    config.stereoDepth = 50;
    config.swapEyes3D = NO;
    config.anisotropy = 4;
    config.diskShaderCache = YES;
    config.layoutOption = AZLayoutOptionDefault;
    config.portraitLayoutOption = AZPortraitLayoutOptionTopFullWidth;
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
