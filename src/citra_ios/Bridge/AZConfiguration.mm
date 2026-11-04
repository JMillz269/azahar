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
    config.resolutionFactor = 1;
    config.linearFiltering = YES;
    config.textureFilter = 0;
    config.skipDuplicateFrames = NO;
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
