// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

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

/// Holds each frame on screen for the time of an emulated frame so frames are evenly spaced.
void SetFramePacing(bool enabled);

/// Fragment shader math and texture sampling options. They apply to games started afterwards.
struct QualityOptions {
    /// Compile fragment shaders with fast math (assumes no NaN/Inf, allows reassociation). Faster,
    /// but can change the result of a shader that relies on exact floating point behaviour.
    bool fast_math = false;
    /// Fragment lighting in half precision with fast normalization. Faster on Apple GPUs, the
    /// lighting can come out very slightly different (lookup table positions are less exact).
    bool fast_lighting = false;
    /// Maximum anisotropic filtering level for linearly filtered textures, 1 disables it.
    int max_anisotropy = 4;
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
