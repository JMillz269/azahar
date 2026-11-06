// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <algorithm>
#include "citra_ios/Bridge/emu_window_ios.h"
#include "common/logging/log.h"

EmuWindow_iOS::EmuWindow_iOS(void* metal_layer, unsigned width, unsigned height, bool portrait,
                             bool is_secondary)
    : Frontend::EmuWindow{is_secondary} {
    window_info.type = Frontend::WindowSystemType::MacOS;
    window_info.render_surface = metal_layer;
    window_info.render_surface_scale = 1.0f;
    UpdateCurrentFramebufferLayout(std::max(width, 1u), std::max(height, 1u), portrait);
}

EmuWindow_iOS::~EmuWindow_iOS() = default;

void EmuWindow_iOS::OnSurfaceChanged(void* metal_layer, unsigned width, unsigned height,
                                     bool portrait) {
    std::scoped_lock lock{mutex};
    if (window_info.render_surface != metal_layer) {
        window_info.render_surface = metal_layer;
        surface_changed = true;
    }
    if (width == 0 || height == 0) {
        return;
    }
    UpdateCurrentFramebufferLayout(width, height, portrait);
}

void EmuWindow_iOS::OnTouchPressed(unsigned x, unsigned y) {
    TouchPressed(x, y);
}

void EmuWindow_iOS::OnTouchMoved(unsigned x, unsigned y) {
    TouchMoved(x, y);
}

void EmuWindow_iOS::OnTouchReleased() {
    TouchReleased();
}
