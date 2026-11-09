// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Makes the frame between two finished frames. Implemented by the app (with Apple's frame
/// interpolation), called by the renderer on its thread. The frames live in numbered slots of
/// textures that the generator owns, because the interpolation reads and writes pixel buffers.
@protocol AZFrameGenerating <NSObject>

/// Gets ready for frames of this size. Returns NO when interpolation is not possible.
- (BOOL)prepareWithDevice:(id<MTLDevice>)device
                    width:(NSInteger)width
                   height:(NSInteger)height NS_SWIFT_NAME(prepare(device:width:height:));

/// The texture of a slot, which the renderer draws a frame into and copies from.
- (nullable id<MTLTexture>)textureForSlot:(NSInteger)slot NS_SWIFT_NAME(texture(slot:));

/// Encodes the frame between the frames in the `previous` and `current` slots into `destination`.
- (BOOL)interpolateFromSlot:(NSInteger)previous
                     toSlot:(NSInteger)current
                   intoSlot:(NSInteger)destination
              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
    NS_SWIFT_NAME(interpolate(from:to:into:commandBuffer:));

@end

NS_ASSUME_NONNULL_END
