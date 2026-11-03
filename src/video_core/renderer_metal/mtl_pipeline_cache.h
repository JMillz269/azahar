// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <unordered_map>
#include "common/hash.h"
#include "video_core/renderer_metal/mtl_common.h"
#include "video_core/shader/generator/pica_fs_config.h"

namespace Pica {
struct RegsInternal;
}

namespace Metal {

class Instance;

/// Fixed function state baked into a MTLRenderPipelineState.
struct PipelineKey {
    u64 fs_hash;
    u32 color_format;   ///< MTLPixelFormat
    u32 depth_format;   ///< MTLPixelFormat
    u32 stencil_format; ///< MTLPixelFormat
    u8 blend_enable;
    u8 rgb_op;     ///< MTLBlendOperation
    u8 alpha_op;   ///< MTLBlendOperation
    u8 src_rgb;    ///< MTLBlendFactor
    u8 dst_rgb;    ///< MTLBlendFactor
    u8 src_alpha;  ///< MTLBlendFactor
    u8 dst_alpha;  ///< MTLBlendFactor
    u8 write_mask; ///< MTLColorWriteMask
    u8 pad[4];

    u64 Hash() const noexcept {
        return Common::ComputeHash64(this, sizeof(PipelineKey));
    }
};
static_assert(std::has_unique_object_representations_v<PipelineKey>);

/// Depth/stencil state baked into a MTLDepthStencilState.
struct DepthStencilKey {
    u8 depth_compare; ///< MTLCompareFunction
    u8 depth_write;
    u8 stencil_enable;
    u8 stencil_compare; ///< MTLCompareFunction
    u8 stencil_fail;    ///< MTLStencilOperation
    u8 depth_fail;      ///< MTLStencilOperation
    u8 depth_pass;      ///< MTLStencilOperation
    u8 read_mask;
    u8 write_mask;
    u8 pad[3];

    u64 Hash() const noexcept {
        return Common::ComputeHash64(this, sizeof(DepthStencilKey));
    }
};
static_assert(std::has_unique_object_representations_v<DepthStencilKey>);

/**
 * Generates, compiles and caches the MSL programs and the pipeline/depth-stencil state objects
 * used by the rasterizer.
 */
class PipelineCache {
public:
    explicit PipelineCache(const Instance& instance, MTLVertexDescriptor* vertex_descriptor);
    ~PipelineCache();

    /// Returns the shader generator profile.
    const Pica::Shader::Profile& GetProfile() const;

    /**
     * Returns the fragment function for the current PICA state, generating and compiling it if
     * it was never seen before. Returns nil if compilation failed.
     * @param fs_hash Receives the hash identifying the function.
     */
    id<MTLFunction> UseFragmentShader(const Pica::RegsInternal& regs,
                                      const Pica::Shader::UserConfig& user,
                                      bool has_color_attachment, u64& fs_hash);

    /// Returns the pipeline state for the provided key and fragment function.
    id<MTLRenderPipelineState> GetPipeline(const PipelineKey& key, id<MTLFunction> fragment);

    /// Returns the depth/stencil state for the provided key.
    id<MTLDepthStencilState> GetDepthStencilState(const DepthStencilKey& key);

    /// Queries whether min/max blending has to be emulated in the fragment shader.
    void QueryBlendEmulation(const Pica::RegsInternal& regs, bool& rgb_emulation,
                             bool& alpha_emulation) const;

    /// Number of fragment programs compiled so far.
    std::size_t NumPrograms() const {
        return fragment_functions.size();
    }

private:
    id<MTLLibrary> Compile(const std::string& source, std::string_view name);

private:
    const Instance& instance;
    MTLVertexDescriptor* vertex_descriptor;
    MTLCompileOptions* compile_options;
    id<MTLFunction> vertex_function;
    std::unordered_map<u64, id<MTLFunction>> fragment_functions;
    std::unordered_map<u64, id<MTLRenderPipelineState>> pipelines;
    std::unordered_map<u64, id<MTLDepthStencilState>> depth_stencil_states;
};

} // namespace Metal
