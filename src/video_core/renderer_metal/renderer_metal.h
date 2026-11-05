// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <memory>

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
