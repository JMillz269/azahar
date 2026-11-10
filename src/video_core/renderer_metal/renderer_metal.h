// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <functional>

#include <memory>
#include <string>
#include <vector>
#include "common/common_types.h"

// Public entry point of the native Metal renderer. This header is plain C++ so it can be included
// from the rest of the code base; the implementation is Objective-C++.

namespace Core {
class System;
}

namespace Frontend {
class EmuWindow;
}

namespace Pica {
class PicaCore;
}

namespace VideoCore {
class RendererBase;
}

namespace Metal {

/// How the 3DS screens are scaled up to the display.
enum class UpscalerMode : int {
    /// Plain texture filtering.
    Off = 0,
    /// MetalFX spatial upscaling: each screen is rendered at the game's internal resolution and
    /// scaled to its size on the display by the GPU's upscaler. Applies from the next frame.
    Spatial = 1,
};

void SetUpscalerMode(UpscalerMode mode);

/// Built-in post-processing (0 none, 1 sharpen, 2 LCD grid, 3 scanlines) and the anaglyph variant
/// (0 Dubois, 1 gray, 2 half color, 3 color). Both apply at once.
void SetPostProcessing(int effect, int anaglyph_mode);

/// A Metal file with a post_effect function that replaces the built-in effect, applied to games
/// started afterwards. See the post-processing section of the iOS settings. Empty for none.
void SetCustomPostShader(const std::string& path);

/// Holds each frame on screen for the time of an emulated frame so frames are evenly spaced.
void SetFramePacing(bool enabled);

/// How textures are kept in GPU memory, see Surface::CreateTexture.
enum class TextureCompression : int {
    Off = 0,
    Lossless = 1, ///< The GPU's lossless compression, identical results
    Lossy = 2,    ///< Lossy compression (A15 and later), lossless on older GPUs
};

/// Hooks of the frame generator, which the app provides (see AZFrameGenerating). Textures and
/// command buffers are passed as the Objective-C objects behind the pointers.
struct FrameGeneratorHooks {
    /// Gets ready for frames of this size (the device is an id<MTLDevice>).
    std::function<bool(void* device, u32 width, u32 height)> prepare;
    /// A plane of a slot (id<MTLTexture>): 0 luma (R8), 1 chroma (RG8, half size). The frames are
    /// 4:2:0 YCbCr, the only format the interpolation takes. nullptr when there is none.
    std::function<void*(u32 slot, u32 plane)> texture;
    /// Starts making the frame between `previous` and `current` into `destination` (the planes
    /// must be written already). `done` is called on another thread when it is finished, with
    /// whether it worked. Returns false when it could not start (`done` is not called then).
    std::function<bool(u32 previous, u32 current, u32 destination,
                       std::function<void(bool made)> done)>
        interpolate;
};
void SetFrameGeneratorHooks(FrameGeneratorHooks hooks);

/// Fragment shader math and texture sampling options. They apply to games started afterwards.
struct QualityOptions {
    /// Compile fragment shaders with fast math (assumes no NaN/Inf, allows reassociation). Faster,
    /// but can change the result of a shader that relies on exact floating point behaviour.
    bool fast_math = false;
    /// Fragment lighting in half precision with fast normalization. Faster on Apple GPUs, the
    /// lighting can come out very slightly different (lookup table positions are less exact).
    bool fast_lighting = false;
    /// Map the depth in the vertex shader so fragment shaders do not write it, which keeps the
    /// hidden surface removal of Apple GPUs working (not for W-buffering).
    bool vertex_depth = false;
    /// Texture combiners in half precision.
    bool fast_color = false;
    TextureCompression texture_compression = TextureCompression::Off;
    /// Small depth areas the CPU reads every frame get the previous frame's values instead of
    /// waiting for the GPU (Mario Kart 7's sun glare check).
    bool async_depth_readback = false;
    /// Maximum anisotropic filtering level for linearly filtered textures, 1 disables it.
    int max_anisotropy = 4;
    /// A frame in which a draw was skipped (its shader was still being built) is not shown, the
    /// previous frame stays (at most three in a row), instead of a frame with parts missing.
    bool hold_frames_for_shaders = false;
    /// Frame generation: 0 off, 1 for games below 40 FPS only, 2 for every game.
    int frame_generation = 0;
    /// Make the frames at 3/8 of the screen size instead of half: faster, softer made frames.
    bool frame_generation_fast = false;
    /// Make frames for the top screen only; the bottom screen shows the game's own frames.
    bool frame_generation_top_only = false;
    /// Highest refresh rate of the display, frame generation for 60 FPS games needs 100 or more.
    int display_hz = 60;
    /// How long (microseconds) a draw waits for its shader to build before it is skipped.
    u32 shader_wait_us = 0;
};
void SetQualityOptions(const QualityOptions& options);
const QualityOptions& GetQualityOptions();

/// Averages per presented frame since the previous call.
struct FrameStats {
    double gpu_ms = 0.0;   ///< GPU time
    double present_ms = 0.0; ///< Part of the GPU time spent presenting (MetalFX, screens)
    double stall_ms = 0.0; ///< Time the emulation thread waited for the GPU (readbacks, pacing)
    double stalls = 0.0;   ///< Number of those waits
    double draws = 0.0;    ///< Draw calls
    double skipped = 0.0;  ///< Draws skipped while their pipeline was being built
    double render_passes = 0.0;   ///< Render passes (each loads and stores its attachments)
    double blit_passes = 0.0;     ///< Blit passes (copies, uploads), each splits a render pass
    double feedback_copies = 0.0; ///< Copies of a render target that is also sampled
    double drawable_ms = 0.0;     ///< Time waiting for the layer to hand out a drawable
    double present_interval_ms = 0.0; ///< Average time between frames reaching the display
    double present_jitter_ms = 0.0;   ///< Standard deviation of that time
    double fg_ms = 0.0;      ///< GPU time per made frame (frame generation)
    double fg_made = 0.0;    ///< Frames made in the interval
    double fg_skipped = 0.0; ///< Frames not made because the previous one was still being made
    double present_late = 0.0;        ///< Frames shown clearly later than the frame time, per second
    u32 frames = 0;
};
FrameStats TakeFrameStats();

/// Where the GPU readbacks of the last interval came from, see mtl_scheduler.h.
std::vector<std::string> TakeReadbackSummary(std::size_t max_lines);

/// What the render passes of the last interval were, see mtl_scheduler.h.
std::vector<std::string> TakeRenderPassSummary(std::size_t max_lines);

/// Whether MetalFX upscaling can be used on this device.
bool IsUpscalingSupported();

/**
 * Creates the Metal renderer. The render surface of the window (WindowSystemInfo::render_surface)
 * must be a CAMetalLayer, which the renderer configures and presents to.
 */
std::unique_ptr<VideoCore::RendererBase> CreateRenderer(Core::System& system, Pica::PicaCore& pica,
                                                        Frontend::EmuWindow& window,
                                                        Frontend::EmuWindow* secondary_window);

} // namespace Metal
