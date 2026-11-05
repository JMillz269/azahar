// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include "video_core/rasterizer_accelerated.h"
#include "video_core/renderer_metal/mtl_pipeline_cache.h"
#include "video_core/renderer_metal/mtl_stream_buffer.h"
#include "video_core/renderer_metal/mtl_texture_runtime.h"
#include "video_core/shader/generator/msl_shader_gen.h"
#include "video_core/shader/generator/shader_uniforms.h"

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
    bool AccelerateDrawBatch(bool is_indexed) override;
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
    void BindShadowCube(const Pica::TexturingRegs::FullTextureConfig& texture,
                        id<MTLTexture> null_storage);
    void BindTextureCube(const Pica::TexturingRegs::FullTextureConfig& texture);

    /// Syncs and uploads the lighting, fog and proctex LUTs
    void SyncAndUploadLUTs();
    void SyncAndUploadLUTsLF();

    /// A draw whose vertices are processed by a hardware vertex shader.
    struct HardwareDraw {
        id<MTLFunction> function = nil;
        u64 vs_hash{};
        bool is_indexed{};
        VertexArrayInfo vertex_info{};
        u32 vertex_count{}; ///< Vertices drawn, three per triangle.
        u32 upload_size{};  ///< Bytes of vertex and index data.
        // Filled by UploadHardwareVertices.
        Pica::Shader::Generator::MSL::VSVertexLayout layout{};
        u32 data_offset{};
    };

    /// Copies the PICA vertex and index data of a hardware draw to the vertex buffer.
    void UploadHardwareVertices(HardwareDraw& draw);

    /**
     * Draws the software vertex batch, or the current PICA draw call with a hardware vertex shader
     * when `hw_draw` is provided.
     */
    bool Draw(HardwareDraw* hw_draw = nullptr);

private:
    Scheduler& scheduler;
    TextureRuntime runtime;
    RasterizerCache res_cache;
    PipelineCache pipeline_cache;

    StreamBuffer vertex_buffer;     ///< Vertex data of the software vertex path
    StreamBuffer texture_buffer;    ///< Proctex LUTs (float2 + float4)
    StreamBuffer texture_lf_buffer; ///< Lighting and fog LUTs (float2)

    Pica::Shader::Generator::VSPicaUniformData vs_pica_data{};

    std::array<TextureBinding, 10> texture_bindings{};
    u64 bound_generation{~0ULL};
};

} // namespace Metal
