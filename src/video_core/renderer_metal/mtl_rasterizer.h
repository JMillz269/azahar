// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include "video_core/rasterizer_accelerated.h"
#include "video_core/renderer_metal/mtl_pipeline_cache.h"
#include "video_core/renderer_metal/mtl_stream_buffer.h"
#include "video_core/renderer_metal/mtl_texture_runtime.h"

namespace VideoCore {
class CustomTexManager;
class RendererBase;
} // namespace VideoCore

namespace Pica {
struct FramebufferConfig;
}

namespace Metal {

class Instance;
class Scheduler;

/// Texture the presentation code draws for one of the 3DS screens.
struct ScreenInfo {
    id<MTLTexture> texture = nil;
    Common::Rectangle<f32> texcoords{0.f, 0.f, 1.f, 1.f};
    u32 width = 0;
    u32 height = 0;
};

class RasterizerMetal : public VideoCore::RasterizerAccelerated {
public:
    explicit RasterizerMetal(Memory::MemorySystem& memory, Pica::PicaCore& pica,
                             VideoCore::CustomTexManager& custom_tex_manager,
                             VideoCore::RendererBase& renderer, const Instance& instance,
                             Scheduler& scheduler);
    ~RasterizerMetal() override;

    void TickFrame();
    void LoadDefaultDiskResources(const std::atomic_bool& stop_loading,
                                  const VideoCore::DiskResourceLoadCallback& callback) override;

    void DrawTriangles() override;
    void FlushAll() override;
    void FlushRegion(PAddr addr, u32 size) override;
    void InvalidateRegion(PAddr addr, u32 size) override;
    void FlushAndInvalidateRegion(PAddr addr, u32 size) override;
    void ClearAll(bool flush) override;
    bool AccelerateDisplayTransfer(const Pica::DisplayTransferConfig& config) override;
    bool AccelerateTextureCopy(const Pica::DisplayTransferConfig& config) override;
    bool AccelerateFill(const Pica::MemoryFillConfig& config) override;
    bool AccelerateDisplay(const Pica::FramebufferConfig& config, PAddr framebuffer_addr,
                           u32 pixel_stride, ScreenInfo& screen_info);

private:
    /// Binding of a fragment texture slot.
    struct TextureBinding {
        id<MTLTexture> texture = nil;
        id<MTLSamplerState> sampler = nil;
    };

    /// Builds the vertex descriptor matching HardwareVertex.
    static MTLVertexDescriptor* MakeVertexDescriptor();

    /// Builds the pipeline and depth/stencil keys from the PICA registers.
    void SyncFixedState(const Framebuffer& framebuffer, u64 fs_hash, PipelineKey& pipeline_key,
                        DepthStencilKey& depth_stencil_key) const;

    /// Syncs all enabled PICA texture units
    void SyncTextureUnits(const Framebuffer& framebuffer);

    /// Binds the PICA shadow cube or texture cube to texture unit 0
    void BindShadowCube(const Pica::TexturingRegs::FullTextureConfig& texture);
    void BindTextureCube(const Pica::TexturingRegs::FullTextureConfig& texture);

    /// Syncs and uploads the lighting, fog and proctex LUTs
    void SyncAndUploadLUTs();
    void SyncAndUploadLUTsLF();

    /// Generic draw function for DrawTriangles
    bool Draw();

private:
    const Instance& instance;
    Scheduler& scheduler;
    TextureRuntime runtime;
    RasterizerCache res_cache;
    PipelineCache pipeline_cache;

    StreamBuffer vertex_buffer;     ///< Vertex data of the software vertex path
    StreamBuffer texture_buffer;    ///< Proctex LUTs (float2 + float4)
    StreamBuffer texture_lf_buffer; ///< Lighting and fog LUTs (float2)

    std::array<TextureBinding, 10> texture_bindings{};
    u64 bound_generation{~0ULL};
};

} // namespace Metal
