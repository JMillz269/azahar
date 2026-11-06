// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <memory>
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

/// Fragment shader math and texture sampling options. They apply to games started afterwards.
struct QualityOptions {
    /// Compile fragment shaders with fast math (assumes no NaN/Inf, allows reassociation). Faster,
    /// but can change the result of a shader that relies on exact floating point behaviour.
    bool fast_math = false;
    /// Maximum anisotropic filtering level for linearly filtered textures, 1 disables it.
    int max_anisotropy = 4;
};
void SetQualityOptions(const QualityOptions& options);
const QualityOptions& GetQualityOptions();

/// Averages per presented frame since the previous call.
struct FrameStats {
    double gpu_ms = 0.0;   ///< GPU time
    double stall_ms = 0.0; ///< Time the emulation thread waited for the GPU (readbacks, pacing)
    double stalls = 0.0;   ///< Number of those waits
    double draws = 0.0;    ///< Draw calls
    double skipped = 0.0;  ///< Draws skipped while their pipeline was being built
    u32 frames = 0;
};
FrameStats TakeFrameStats();

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
