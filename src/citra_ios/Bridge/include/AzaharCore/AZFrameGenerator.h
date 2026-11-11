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

/// A plane of a slot: 0 the luma (R8), 1 the chroma (RG8, half the size). The frames are 4:2:0
/// YCbCr, which is what the interpolation takes. The renderer writes and reads these.
- (nullable id<MTLTexture>)textureForSlot:(NSInteger)slot
                                    plane:(NSInteger)plane NS_SWIFT_NAME(texture(slot:plane:));

/// Starts making the frame between the frames in the `previous` and `current` slots into
/// `destination`. `completion` is called (on any thread) once it is written, with whether it
/// worked. Returns NO, without calling `completion`, when it could not start.
- (BOOL)interpolateFromSlot:(NSInteger)previous
                     toSlot:(NSInteger)current
                   intoSlot:(NSInteger)destination
                 completion:(void (^)(BOOL made))completion
    NS_SWIFT_NAME(interpolate(from:to:into:completion:));

/// The same, encoded into `commandBuffer` (which the renderer commits, after the command buffer with
/// the picture) instead of being started. Returns NO when it could not be encoded.
- (BOOL)interpolateFromSlot:(NSInteger)previous
                     toSlot:(NSInteger)current
                   intoSlot:(NSInteger)destination
              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
    NS_SWIFT_NAME(interpolate(from:to:into:commandBuffer:));

@end

NS_ASSUME_NONNULL_END
