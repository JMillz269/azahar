// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <string>
#include "common/common_types.h"
#include "video_core/shader/generator/pica_fs_config.h"

/**
 * Metal Shading Language (MSL) shader generators used by the native Metal renderer.
 *
 * The Metal renderer follows the Vulkan conventions of the other backends (top-left framebuffer
 * origin, [0, 1] depth range, same memory layout of the rasterizer cache surfaces). The only
 * difference is that Metal's normalized device coordinates have +Y pointing up while Vulkan's
 * point down, so the vertex shader negates Y compared to the Vulkan backend.
 *
 * Resource binding model (shared between the generators and the Metal rasterizer):
 */
namespace Pica::Shader::Generator::MSL {

/// Vertex stage buffer indices.
enum VSBuffer : u32 {
    VS_BUFFER_UNIFORMS = 0,      ///< VSUniformData
    VS_BUFFER_PICA_UNIFORMS = 1, ///< VSPicaUniformData (hardware vertex shaders)
    /// Vertex buffers are placed after the uniform buffers in the argument table.
    VS_BUFFER_VERTEX_BASE = 16,
};

/// Fragment stage buffer indices.
enum FSBuffer : u32 {
    FS_BUFFER_UNIFORMS = 0, ///< FSUniformData
    FS_BUFFER_LUT_LF = 1,   ///< float2 lighting + fog LUT
    FS_BUFFER_LUT_RG = 2,   ///< float2 proctex noise/color-map/alpha-map LUT
    FS_BUFFER_LUT_RGBA = 3, ///< float4 proctex color LUT
};

/// Fragment stage texture indices. Shadow cube maps use slots [0, 5] for texture unit 0.
enum FSTexture : u32 {
    FS_TEXTURE_0 = 0,
    FS_TEXTURE_1 = 6,
    FS_TEXTURE_2 = 7,
    FS_TEXTURE_NORMAL = 8,
    FS_TEXTURE_SHADOW_BUFFER = 9,
};

/// Fragment stage sampler indices.
enum FSSampler : u32 {
    FS_SAMPLER_0 = 0,
    FS_SAMPLER_1 = 1,
    FS_SAMPLER_2 = 2,
    FS_SAMPLER_NORMAL = 3,
};

/// Name of the entry points of the generated programs.
constexpr const char* VS_ENTRY_POINT = "vs_main";
constexpr const char* FS_ENTRY_POINT = "fs_main";

/**
 * Additional state the Metal backend needs to generate a fragment shader that is not part of the
 * PICA configuration.
 */
struct MetalFSConfig {
    /// True if a color attachment is bound, so framebuffer fetch ([[color(0)]]) can be used to
    /// emulate logic ops and min/max blending with factors.
    bool has_color_attachment = true;
};

/// Returns the vertex shader used by the software (CPU) vertex processing path.
std::string GenerateTrivialVertexShader(bool use_clip_planes);

/**
 * Generates the MSL fragment shader program source code for the current Pica state.
 * @param config Configuration generated from the current Pica state. Only use the state in this
 *               struct, not the Pica registers.
 */
std::string GenerateFragmentShader(const FSConfig& config, const UserConfig& user,
                                   const Profile& profile, const MetalFSConfig& metal_config);

} // namespace Pica::Shader::Generator::MSL
