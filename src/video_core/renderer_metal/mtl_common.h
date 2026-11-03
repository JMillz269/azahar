// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

// The Metal backend is written in Objective-C++ with ARC. Internal headers expose Objective-C
// types and must only be included from .mm translation units. The renderer entry point that the
// rest of the code base uses lives in renderer_metal.h and is plain C++.
#ifndef __OBJC__
#error "Metal backend internal headers must only be included from Objective-C++ sources"
#endif

#if !__has_feature(objc_arc)
#error "The Metal backend must be compiled with ARC (-fobjc-arc)"
#endif

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string_view>
#include "common/common_types.h"

namespace Metal {

/// Converts a std::string_view to an autoreleased NSString.
inline NSString* ToNSString(std::string_view str) {
    return [[NSString alloc] initWithBytes:str.data()
                                    length:str.size()
                                  encoding:NSUTF8StringEncoding];
}

/// Sets the debug label of a Metal object when the string is not empty.
template <typename T>
inline void SetLabel(T object, std::string_view label) {
    if (!label.empty()) {
        object.label = ToNSString(label);
    }
}

} // namespace Metal
