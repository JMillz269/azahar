// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include "video_core/rasterizer_cache/rasterizer_cache.h"
#include "video_core/renderer_metal/mtl_texture_runtime.h"

namespace VideoCore {
template class RasterizerCache<Metal::Traits>;
} // namespace VideoCore
