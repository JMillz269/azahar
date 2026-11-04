// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <atomic>
#include <mutex>
#include "core/frontend/emu_window.h"

/**
 * Emulator window backed by a CAMetalLayer owned by the SwiftUI frontend. The Metal renderer
 * reads the layer from WindowSystemInfo::render_surface.
 */
class EmuWindow_iOS final : public Frontend::EmuWindow {
public:
    explicit EmuWindow_iOS(void* metal_layer, unsigned width, unsigned height, bool portrait);
    ~EmuWindow_iOS() override;

    void PollEvents() override {}

    /// Updates the drawable size (pixels) and orientation, recomputing the screen layout.
    void OnSurfaceChanged(void* metal_layer, unsigned width, unsigned height, bool portrait);

    /// Touch handling, coordinates in drawable pixels.
    void OnTouchPressed(unsigned x, unsigned y);
    void OnTouchMoved(unsigned x, unsigned y);
    void OnTouchReleased();

    /// Returns true (once) when the surface changed and the renderer must be notified.
    bool TakeSurfaceChanged() {
        return surface_changed.exchange(false);
    }

private:
    std::mutex mutex;
    std::atomic<bool> surface_changed{};
};
