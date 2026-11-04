// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include "common/logging/log.h"
#include "common/microprofile.h"
#include "common/settings.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/renderer_metal/mtl_instance.h"
#include "video_core/renderer_metal/mtl_pipeline_cache.h"
#include "video_core/shader/generator/msl_shader_gen.h"

MICROPROFILE_DEFINE(Metal_ShaderCompile, "Metal", "Shader Compile", MP_RGB(255, 128, 0));
MICROPROFILE_DEFINE(Metal_PipelineBuild, "Metal", "Pipeline Build", MP_RGB(255, 64, 0));

namespace Metal {

using namespace Pica::Shader::Generator;

PipelineCache::PipelineCache(const Instance& instance_, MTLVertexDescriptor* vertex_descriptor_)
    : instance{instance_}, vertex_descriptor{vertex_descriptor_} {
    compile_options = [MTLCompileOptions new];
    if (@available(iOS 16.0, macOS 13.0, *)) {
        compile_options.languageVersion = MTLLanguageVersion2_4;
    }
    // Keep the position output bit-exact between pipelines sharing geometry (multi-pass effects).
    if (@available(iOS 14.0, macOS 11.0, *)) {
        compile_options.preserveInvariance = YES;
    }
    if (@available(iOS 18.0, macOS 15.0, *)) {
        compile_options.mathMode = MTLMathModeSafe;
    } else {
        compile_options.fastMathEnabled = NO;
    }

    id<MTLLibrary> vs_library =
        Compile(MSL::GenerateTrivialVertexShader(instance.GetProfile().has_clip_planes),
                "trivial vertex shader");
    ASSERT_MSG(vs_library, "Failed to compile the Metal vertex shader");
    vertex_function = [vs_library newFunctionWithName:ToNSString(MSL::VS_ENTRY_POINT)];
}

PipelineCache::~PipelineCache() = default;

const Pica::Shader::Profile& PipelineCache::GetProfile() const {
    return instance.GetProfile();
}

id<MTLLibrary> PipelineCache::Compile(const std::string& source, std::string_view name) {
    MICROPROFILE_SCOPE(Metal_ShaderCompile);
    NSError* error = nil;
    id<MTLLibrary> library = [instance.GetDevice() newLibraryWithSource:ToNSString(source)
                                                                options:compile_options
                                                                  error:&error];
    if (!library) {
        LOG_CRITICAL(Render, "Failed to compile {}: {}\n{}", name,
                     error ? [error.localizedDescription UTF8String] : "unknown error", source);
    } else if (error && Settings::values.renderer_debug) {
        LOG_WARNING(Render, "Warnings compiling {}: {}", name,
                    [error.localizedDescription UTF8String]);
    }
    return library;
}

id<MTLFunction> PipelineCache::UseFragmentShader(const Pica::RegsInternal& regs,
                                                 const Pica::Shader::UserConfig& user,
                                                 bool has_color_attachment,
                                                 bool has_depth_attachment, u64& fs_hash) {
    const Pica::Shader::FSConfig fs_config{regs};
    MSL::MetalFSConfig metal_config{};
    metal_config.has_color_attachment = has_color_attachment;
    metal_config.has_depth_attachment = has_depth_attachment;

    fs_hash = Common::HashCombine(fs_config.Hash(), static_cast<u64>(user.raw),
                                  static_cast<u64>(has_color_attachment),
                                  static_cast<u64>(has_depth_attachment));
    if (const auto it = fragment_functions.find(fs_hash); it != fragment_functions.end()) {
        return it->second;
    }

    const std::string source =
        MSL::GenerateFragmentShader(fs_config, user, instance.GetProfile(), metal_config);
    id<MTLLibrary> library = Compile(source, "fragment shader");
    id<MTLFunction> function =
        library ? [library newFunctionWithName:ToNSString(MSL::FS_ENTRY_POINT)] : nil;
    fragment_functions.emplace(fs_hash, function);
    return function;
}

id<MTLRenderPipelineState> PipelineCache::GetPipeline(const PipelineKey& key,
                                                      id<MTLFunction> fragment) {
    const u64 hash = key.Hash();
    if (const auto it = pipelines.find(hash); it != pipelines.end()) {
        return it->second;
    }

    MICROPROFILE_SCOPE(Metal_PipelineBuild);
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vertex_function;
    desc.fragmentFunction = fragment;
    desc.vertexDescriptor = vertex_descriptor;
    desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    desc.rasterSampleCount = 1;

    MTLRenderPipelineColorAttachmentDescriptor* color = desc.colorAttachments[0];
    color.pixelFormat = static_cast<MTLPixelFormat>(key.color_format);
    color.writeMask = static_cast<MTLColorWriteMask>(key.write_mask);
    color.blendingEnabled = key.blend_enable && key.color_format != MTLPixelFormatInvalid;
    color.rgbBlendOperation = static_cast<MTLBlendOperation>(key.rgb_op);
    color.alphaBlendOperation = static_cast<MTLBlendOperation>(key.alpha_op);
    color.sourceRGBBlendFactor = static_cast<MTLBlendFactor>(key.src_rgb);
    color.destinationRGBBlendFactor = static_cast<MTLBlendFactor>(key.dst_rgb);
    color.sourceAlphaBlendFactor = static_cast<MTLBlendFactor>(key.src_alpha);
    color.destinationAlphaBlendFactor = static_cast<MTLBlendFactor>(key.dst_alpha);
    desc.depthAttachmentPixelFormat = static_cast<MTLPixelFormat>(key.depth_format);
    desc.stencilAttachmentPixelFormat = static_cast<MTLPixelFormat>(key.stencil_format);

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [instance.GetDevice() newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        LOG_CRITICAL(Render, "Failed to create Metal pipeline: {}",
                     error ? [error.localizedDescription UTF8String] : "unknown error");
    }
    pipelines.emplace(hash, pipeline);
    return pipeline;
}

id<MTLDepthStencilState> PipelineCache::GetDepthStencilState(const DepthStencilKey& key) {
    const u64 hash = key.Hash();
    if (const auto it = depth_stencil_states.find(hash); it != depth_stencil_states.end()) {
        return it->second;
    }

    MTLDepthStencilDescriptor* desc = [MTLDepthStencilDescriptor new];
    desc.depthCompareFunction = static_cast<MTLCompareFunction>(key.depth_compare);
    desc.depthWriteEnabled = key.depth_write != 0;
    if (key.stencil_enable) {
        MTLStencilDescriptor* stencil = [MTLStencilDescriptor new];
        stencil.stencilCompareFunction = static_cast<MTLCompareFunction>(key.stencil_compare);
        stencil.stencilFailureOperation = static_cast<MTLStencilOperation>(key.stencil_fail);
        stencil.depthFailureOperation = static_cast<MTLStencilOperation>(key.depth_fail);
        stencil.depthStencilPassOperation = static_cast<MTLStencilOperation>(key.depth_pass);
        stencil.readMask = key.read_mask;
        stencil.writeMask = key.write_mask;
        desc.frontFaceStencil = stencil;
        desc.backFaceStencil = stencil;
    }

    id<MTLDepthStencilState> state = [instance.GetDevice() newDepthStencilStateWithDescriptor:desc];
    depth_stencil_states.emplace(hash, state);
    return state;
}

void PipelineCache::QueryBlendEmulation(const Pica::RegsInternal& regs, bool& rgb_emulation,
                                        bool& alpha_emulation) const {
    Pica::Shader::FramebufferConfig framebuffer_config{regs};
    framebuffer_config.ApplyProfile(instance.GetProfile());
    rgb_emulation = framebuffer_config.requested_rgb_blend.RequiresMinMaxEmulation();
    alpha_emulation = framebuffer_config.requested_alpha_blend.RequiresMinMaxEmulation();
}

} // namespace Metal
