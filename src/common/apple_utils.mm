// Copyright 2025-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#endif
#import <Foundation/Foundation.h>

namespace AppleUtils {

#if TARGET_OS_IPHONE
float GetRefreshRate() {
    // UIScreen may only be used from the main thread. Don't block on it from other threads (the
    // main thread may be waiting on the emulation thread), assume 60Hz there instead.
    if (![NSThread isMainThread]) {
        return 60.0f;
    }
    const NSInteger fps = [UIScreen mainScreen].maximumFramesPerSecond;
    return fps > 0 ? static_cast<float>(fps) : 60.0f;
}
#else
float GetRefreshRate() { // TODO: How does this handle multi-monitor? -OS
    NSScreen* screen = [NSScreen mainScreen];
    if (screen) {
        NSDictionary* screenInfo = [screen deviceDescription];
        CGDirectDisplayID displayID =
            (CGDirectDisplayID)[screenInfo[@"NSScreenNumber"] unsignedIntValue];
        CGDisplayModeRef displayMode = CGDisplayCopyDisplayMode(displayID);
        if (displayMode) {
            CGFloat refreshRate = CGDisplayModeGetRefreshRate(displayMode);
            CFRelease(displayMode);
            return refreshRate;
        }
    }

    return 60; // Something went wrong, so just return a generic value
}
#endif

int IsLowPowerModeEnabled() {
    return (int)[NSProcessInfo processInfo].lowPowerModeEnabled;
}

} // namespace AppleUtils
