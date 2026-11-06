// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <algorithm>
#include <cstring>
#include "common/alignment.h"
#include "common/assert.h"
#include "common/literals.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "video_core/custom_textures/custom_format.h"
#include "video_core/custom_textures/material.h"
#include "video_core/rasterizer_cache/texture_codec.h"
#include "video_core/rasterizer_cache/utils.h"
#include "video_core/renderer_metal/mtl_texture_runtime.h"
#include "video_core/renderer_metal/mtl_utility_shaders.h"
#include "video_core/renderer_metal/pica_to_mtl.h"
#include "video_core/renderer_metal/renderer_metal.h"

namespace Metal {

namespace {

using namespace Common::Literals;
using VideoCore::MapType;
using VideoCore::PixelFormat;
using VideoCore::SurfaceType;
using VideoCore::TextureType;

constexpr u64 UPLOAD_BUFFER_SIZE = 64_MiB;
constexpr u64 DOWNLOAD_BUFFER_SIZE = 16_MiB;

struct BlitParams {
    std::array<f32, 4> src_rect;
    std::array<f32, 4> color;
    f32 depth;
    f32 lod;
    std::array<f32, 2> pad;
};
static_assert(sizeof(BlitParams) == 48);

id<MTLLibrary> CompileLibrary(id<MTLDevice> device, std::string_view source,
                              std::string_view name) {
    MTLCompileOptions* options = [MTLCompileOptions new];
    if (@available(iOS 16.0, macOS 13.0, *)) {
        options.languageVersion = MTLLanguageVersion2_4;
    }
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:ToNSString(source)
                                                  options:options
                                                    error:&error];
    if (!library) {
        LOG_CRITICAL(Render, "Failed to compile Metal library {}: {}", name,
                     error ? [error.localizedDescription UTF8String] : "unknown error");
    }
    return library;
}

/// Returns the size of a texture level.
std::pair<u32, u32> LevelExtent(id<MTLTexture> texture, u32 level) {
    return {std::max<u32>(static_cast<u32>(texture.width) >> level, 1u),
            std::max<u32>(static_cast<u32>(texture.height) >> level, 1u)};
}

/// Returns a 2D single level/slice view of a texture, used as a blit source.
id<MTLTexture> MakeLevelView(id<MTLTexture> texture, MTLPixelFormat format, u32 level, u32 slice) {
    return [texture newTextureViewWithPixelFormat:format
                                      textureType:MTLTextureType2D
                                           levels:NSMakeRange(level, 1)
                                           slices:NSMakeRange(slice, 1)];
}

/// Returns the bytes per row and rows of a custom texture level.
std::pair<u32, u32> CustomLayout(VideoCore::CustomPixelFormat format, u32 width, u32 height) {
    using VideoCore::CustomPixelFormat;
    const auto blocks = [&](u32 block_w, u32 block_h, u32 block_size) {
        const u32 blocks_x = (width + block_w - 1) / block_w;
        const u32 blocks_y = (height + block_h - 1) / block_h;
        return std::make_pair(blocks_x * block_size, blocks_y);
    };
    switch (format) {
    case CustomPixelFormat::BC1:
        return blocks(4, 4, 8);
    case CustomPixelFormat::BC3:
    case CustomPixelFormat::BC5:
    case CustomPixelFormat::BC7:
    case CustomPixelFormat::ASTC4:
        return blocks(4, 4, 16);
    case CustomPixelFormat::ASTC6:
        return blocks(6, 6, 16);
    case CustomPixelFormat::ASTC8:
        return blocks(8, 6, 16);
    case CustomPixelFormat::RGBA8:
    default:
        return {width * 4, height};
    }
}

} // Anonymous namespace

// ===========================================================================================
// BlitHelper
// ===========================================================================================

BlitHelper::BlitHelper(const Instance& instance_, Scheduler& scheduler_)
    : instance{instance_}, scheduler{scheduler_} {
    id<MTLDevice> device = instance.GetDevice();
    library = CompileLibrary(device, Shaders::UTILITY, "utility");
    if (instance.IsStencilExportSupported()) {
        stencil_library = CompileLibrary(device, Shaders::STENCIL, "stencil utility");
    }

    MTLSamplerDescriptor* sampler_desc = [MTLSamplerDescriptor new];
    sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_desc.minFilter = MTLSamplerMinMagFilterLinear;
    sampler_desc.magFilter = MTLSamplerMinMagFilterLinear;
    linear_sampler = [device newSamplerStateWithDescriptor:sampler_desc];
    sampler_desc.minFilter = MTLSamplerMinMagFilterNearest;
    sampler_desc.magFilter = MTLSamplerMinMagFilterNearest;
    nearest_sampler = [device newSamplerStateWithDescriptor:sampler_desc];

    MTLDepthStencilDescriptor* ds_desc = [MTLDepthStencilDescriptor new];
    ds_desc.depthCompareFunction = MTLCompareFunctionAlways;
    ds_desc.depthWriteEnabled = YES;
    depth_write_state = [device newDepthStencilStateWithDescriptor:ds_desc];

    MTLStencilDescriptor* stencil_desc = [MTLStencilDescriptor new];
    stencil_desc.stencilCompareFunction = MTLCompareFunctionAlways;
    stencil_desc.depthStencilPassOperation = MTLStencilOperationReplace;
    stencil_desc.stencilFailureOperation = MTLStencilOperationReplace;
    stencil_desc.depthFailureOperation = MTLStencilOperationReplace;
    stencil_desc.readMask = 0xFF;
    stencil_desc.writeMask = 0xFF;
    ds_desc.frontFaceStencil = stencil_desc;
    ds_desc.backFaceStencil = stencil_desc;
    depth_stencil_write_state = [device newDepthStencilStateWithDescriptor:ds_desc];
}

BlitHelper::~BlitHelper() = default;

id<MTLRenderPipelineState> BlitHelper::GetPipeline(std::string_view function, MTLPixelFormat color,
                                                   MTLPixelFormat depth, MTLPixelFormat stencil) {
    const std::string key = fmt::format("{}:{}:{}:{}", function, static_cast<u64>(color),
                                        static_cast<u64>(depth), static_cast<u64>(stencil));
    if (const auto it = pipelines.find(key); it != pipelines.end()) {
        return it->second;
    }

    id<MTLLibrary> fs_library = function == "blit_depth_stencil_fs" ? stencil_library : library;
    if (!library || !fs_library) {
        return nil;
    }

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"blit_vs"];
    desc.fragmentFunction = [fs_library newFunctionWithName:ToNSString(function)];
    desc.colorAttachments[0].pixelFormat = color;
    desc.depthAttachmentPixelFormat = depth;
    desc.stencilAttachmentPixelFormat = stencil;
    if (color == MTLPixelFormatInvalid) {
        desc.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    }
    desc.label = ToNSString(function);

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [instance.GetDevice() newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        LOG_CRITICAL(Render, "Failed to create utility pipeline {}: {}", function,
                     error ? [error.localizedDescription UTF8String] : "unknown error");
    }
    pipelines.emplace(key, pipeline);
    return pipeline;
}

void BlitHelper::SetupRect(id<MTLRenderCommandEncoder> encoder, id<MTLTexture> dst, u32 dst_level,
                           const Common::Rectangle<u32>& dst_rect,
                           const Common::Rectangle<u32>& src_rect, u32 src_width, u32 src_height,
                           float lod, const Common::Vec4f& color, float depth) {
    // Rectangles use row coordinates where "bottom" is the first row. Either axis can be
    // mirrored, normalize the destination and mirror the source coordinates instead.
    const u32 dst_x0 = std::min(dst_rect.left, dst_rect.right);
    const u32 dst_x1 = std::max(dst_rect.left, dst_rect.right);
    const u32 dst_y0 = std::min(dst_rect.bottom, dst_rect.top);
    const u32 dst_y1 = std::max(dst_rect.bottom, dst_rect.top);
    const bool mirror_x = dst_rect.left > dst_rect.right;
    const bool mirror_y = dst_rect.bottom > dst_rect.top;

    f32 u0 = static_cast<f32>(src_rect.left) / static_cast<f32>(std::max(src_width, 1u));
    f32 u1 = static_cast<f32>(src_rect.right) / static_cast<f32>(std::max(src_width, 1u));
    f32 v0 = static_cast<f32>(src_rect.bottom) / static_cast<f32>(std::max(src_height, 1u));
    f32 v1 = static_cast<f32>(src_rect.top) / static_cast<f32>(std::max(src_height, 1u));
    if (mirror_x) {
        std::swap(u0, u1);
    }
    if (mirror_y) {
        std::swap(v0, v1);
    }

    const auto [level_width, level_height] = LevelExtent(dst, dst_level);
    const u32 x0 = std::min(dst_x0, level_width);
    const u32 y0 = std::min(dst_y0, level_height);
    const u32 x1 = std::min(dst_x1, level_width);
    const u32 y1 = std::min(dst_y1, level_height);

    const MTLViewport viewport = {
        .originX = static_cast<double>(dst_x0),
        .originY = static_cast<double>(dst_y0),
        .width = static_cast<double>(dst_x1 - dst_x0),
        .height = static_cast<double>(dst_y1 - dst_y0),
        .znear = 0.0,
        .zfar = 1.0,
    };
    [encoder setViewport:viewport];
    [encoder setScissorRect:MTLScissorRect{x0, y0, std::max(x1 - x0, 0u), std::max(y1 - y0, 0u)}];

    const BlitParams params = {
        .src_rect = {u0, v0, u1, v1},
        .color = {color.x, color.y, color.z, color.w},
        .depth = depth,
        .lod = lod,
    };
    [encoder setVertexBytes:&params length:sizeof(params) atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
}

void BlitHelper::BlitColor(id<MTLTexture> src, u32 src_level, u32 src_slice,
                           const Common::Rectangle<u32>& src_rect, id<MTLTexture> dst,
                           u32 dst_level, u32 dst_slice, const Common::Rectangle<u32>& dst_rect,
                           bool linear) {
    id<MTLRenderPipelineState> pipeline =
        GetPipeline("blit_color_fs", dst.pixelFormat, MTLPixelFormatInvalid, MTLPixelFormatInvalid);
    if (!pipeline) {
        return;
    }

    id<MTLTexture> src_view = MakeLevelView(src, src.pixelFormat, src_level, src_slice);
    const auto [src_width, src_height] = LevelExtent(src, src_level);

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = dst;
    desc.colorAttachments[0].level = dst_level;
    desc.colorAttachments[0].slice = dst_slice;
    desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    [encoder setRenderPipelineState:pipeline];
    SetupRect(encoder, dst, dst_level, dst_rect, src_rect, src_width, src_height, 0.0f, {}, 0.0f);
    [encoder setFragmentTexture:src_view atIndex:0];
    [encoder setFragmentSamplerState:(linear ? linear_sampler : nearest_sampler) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    scheduler.EndEncoding();
}

void BlitHelper::BlitDepthStencil(id<MTLTexture> src, id<MTLTexture> src_stencil_view,
                                  u32 src_level, const Common::Rectangle<u32>& src_rect,
                                  id<MTLTexture> dst, u32 dst_level,
                                  const Common::Rectangle<u32>& dst_rect) {
    const bool has_stencil = dst.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    const bool copy_stencil = has_stencil && src_stencil_view != nil && stencil_library != nil;
    const MTLPixelFormat stencil_format =
        has_stencil ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    id<MTLRenderPipelineState> pipeline =
        GetPipeline(copy_stencil ? "blit_depth_stencil_fs" : "blit_depth_fs", MTLPixelFormatInvalid,
                    dst.pixelFormat, stencil_format);
    if (!pipeline) {
        return;
    }
    if (has_stencil && !copy_stencil) {
        LOG_WARNING(Render, "Stencil export is not supported, stencil data will be lost on blit");
    }

    id<MTLTexture> src_view = MakeLevelView(src, src.pixelFormat, src_level, 0);
    const auto [src_width, src_height] = LevelExtent(src, src_level);

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.depthAttachment.texture = dst;
    desc.depthAttachment.level = dst_level;
    desc.depthAttachment.loadAction = MTLLoadActionLoad;
    desc.depthAttachment.storeAction = MTLStoreActionStore;
    if (has_stencil) {
        desc.stencilAttachment.texture = dst;
        desc.stencilAttachment.level = dst_level;
        desc.stencilAttachment.loadAction = MTLLoadActionLoad;
        desc.stencilAttachment.storeAction = MTLStoreActionStore;
    }

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:copy_stencil ? depth_stencil_write_state : depth_write_state];
    SetupRect(encoder, dst, dst_level, dst_rect, src_rect, src_width, src_height, 0.0f, {}, 0.0f);
    [encoder setFragmentTexture:src_view atIndex:0];
    if (copy_stencil) {
        [encoder setFragmentTexture:src_stencil_view atIndex:1];
    }
    [encoder setFragmentSamplerState:nearest_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    scheduler.EndEncoding();
}

void BlitHelper::ClearColor(id<MTLTexture> texture, u32 level, u32 slice,
                            const Common::Rectangle<u32>& rect, const Common::Vec4f& color) {
    id<MTLRenderPipelineState> pipeline = GetPipeline("clear_color_fs", texture.pixelFormat,
                                                      MTLPixelFormatInvalid, MTLPixelFormatInvalid);
    if (!pipeline) {
        return;
    }

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = texture;
    desc.colorAttachments[0].level = level;
    desc.colorAttachments[0].slice = slice;
    desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    [encoder setRenderPipelineState:pipeline];
    SetupRect(encoder, texture, level, rect, rect, 1, 1, 0.0f, color, 0.0f);
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    scheduler.EndEncoding();
}

void BlitHelper::ClearDepthStencil(id<MTLTexture> texture, u32 level, bool has_stencil,
                                   const Common::Rectangle<u32>& rect, float depth, u8 stencil) {
    const MTLPixelFormat stencil_format = has_stencil ? texture.pixelFormat : MTLPixelFormatInvalid;
    id<MTLRenderPipelineState> pipeline =
        GetPipeline("clear_depth_fs", MTLPixelFormatInvalid, texture.pixelFormat, stencil_format);
    if (!pipeline) {
        return;
    }

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.depthAttachment.texture = texture;
    desc.depthAttachment.level = level;
    desc.depthAttachment.loadAction = MTLLoadActionLoad;
    desc.depthAttachment.storeAction = MTLStoreActionStore;
    if (has_stencil) {
        desc.stencilAttachment.texture = texture;
        desc.stencilAttachment.level = level;
        desc.stencilAttachment.loadAction = MTLLoadActionLoad;
        desc.stencilAttachment.storeAction = MTLStoreActionStore;
    }

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:has_stencil ? depth_stencil_write_state : depth_write_state];
    [encoder setStencilReferenceValue:stencil];
    SetupRect(encoder, texture, level, rect, rect, 1, 1, 0.0f, {}, depth);
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    scheduler.EndEncoding();
}

// ===========================================================================================
// TextureRuntime
// ===========================================================================================

TextureRuntime::TextureRuntime(const Instance& instance_, Scheduler& scheduler_)
    : instance{instance_}, scheduler{scheduler_}, blit_helper{instance_, scheduler_},
      upload_buffer{instance_, scheduler_, UPLOAD_BUFFER_SIZE, "Upload buffer"},
      download_buffer{instance_, scheduler_, DOWNLOAD_BUFFER_SIZE, "Download buffer", true} {}

TextureRuntime::~TextureRuntime() = default;

VideoCore::StagingData TextureRuntime::FindStaging(u32 size, bool upload) {
    StreamBuffer& buffer = upload ? upload_buffer : download_buffer;
    const auto [data, offset, invalidate] = buffer.Map(size, 16);
    return VideoCore::StagingData{
        .size = size,
        .offset = offset,
        .mapped = std::span{data, size},
    };
}

u64 TextureRuntime::GetResourceTick() {
    return scheduler.CurrentTick();
}

u64 TextureRuntime::GetResourceFreeTick() {
    return scheduler.KnownGpuTick();
}

void TextureRuntime::Finish() {
    scheduler.Finish();
}

bool TextureRuntime::NeedsConversion(const Surface& surface) const {
    // Depth-stencil is de-interleaved by the runtime itself.
    return surface.traits.needs_conversion && !surface.traits.has_stencil;
}

bool TextureRuntime::Reinterpret(Surface& source, Surface& dest,
                                 const VideoCore::TextureCopy& copy) {
    const PixelFormat src_format = source.pixel_format;
    const PixelFormat dst_format = dest.pixel_format;
    ASSERT_MSG(src_format != dst_format, "Reinterpretation with the same format is invalid");

    if (source.traits.native == dest.traits.native && !source.traits.is_depth) {
        // All color formats are stored as RGBA8, so a reinterpretation is a plain copy.
        return CopyTextures(source, dest, copy);
    }

    if (src_format == PixelFormat::D24S8 && dst_format == PixelFormat::RGBA8) {
        id<MTLRenderPipelineState> pipeline = blit_helper.GetPipeline(
            "d24s8_to_rgba8_fs", dest.traits.native, MTLPixelFormatInvalid, MTLPixelFormatInvalid);
        if (!pipeline) {
            return false;
        }
        id<MTLTexture> depth_view =
            MakeLevelView(source.Texture(), source.traits.native, copy.src_level, 0);
        id<MTLTexture> stencil_view =
            MakeLevelView(source.Texture(), MTLPixelFormatX32_Stencil8, copy.src_level, 0);

        MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
        desc.colorAttachments[0].texture = dest.Texture();
        desc.colorAttachments[0].level = copy.dst_level;
        desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
        desc.colorAttachments[0].storeAction = MTLStoreActionStore;

        const Common::Rectangle<u32> dst_rect{
            copy.dst_offset.x, copy.dst_offset.y + copy.extent.height,
            copy.dst_offset.x + copy.extent.width, copy.dst_offset.y};
        id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
        [encoder setRenderPipelineState:pipeline];
        // Reuse the blit parameter setup, then override the source offset.
        blit_helper.SetupRect(encoder, dest.Texture(), copy.dst_level, dst_rect, dst_rect, 1, 1,
                              0.0f, {}, 0.0f);
        const BlitParams params = {
            .src_rect = {static_cast<f32>(copy.src_offset.x) - static_cast<f32>(copy.dst_offset.x),
                         static_cast<f32>(copy.src_offset.y) - static_cast<f32>(copy.dst_offset.y),
                         0.0f, 0.0f},
        };
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
        [encoder setFragmentTexture:depth_view atIndex:0];
        [encoder setFragmentTexture:stencil_view atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        scheduler.EndEncoding();
        return true;
    }

    LOG_WARNING(Render, "Unimplemented reinterpretation {} -> {}",
                VideoCore::PixelFormatAsString(src_format),
                VideoCore::PixelFormatAsString(dst_format));
    return false;
}

bool TextureRuntime::ClearTexture(Surface& surface, const VideoCore::TextureClear& clear) {
    id<MTLTexture> texture = surface.Texture();
    if (!texture) {
        return false;
    }

    const auto [level_width, level_height] = LevelExtent(texture, clear.texture_level);
    const auto& rect = clear.texture_rect;
    const bool full_clear = rect.left == 0 && std::min(rect.bottom, rect.top) == 0 &&
                            rect.GetWidth() >= level_width && rect.GetHeight() >= level_height;

    if (!full_clear) {
        if (surface.IsDepth()) {
            blit_helper.ClearDepthStencil(texture, clear.texture_level, surface.HasStencil(), rect,
                                          clear.value.depth, clear.value.stencil);
        } else {
            blit_helper.ClearColor(texture, clear.texture_level, clear.texture_layer, rect,
                                   clear.value.color);
        }
        return true;
    }

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    if (surface.IsDepth()) {
        desc.depthAttachment.texture = texture;
        desc.depthAttachment.level = clear.texture_level;
        desc.depthAttachment.loadAction = MTLLoadActionClear;
        desc.depthAttachment.storeAction = MTLStoreActionStore;
        desc.depthAttachment.clearDepth = clear.value.depth;
        if (surface.HasStencil()) {
            desc.stencilAttachment.texture = texture;
            desc.stencilAttachment.level = clear.texture_level;
            desc.stencilAttachment.loadAction = MTLLoadActionClear;
            desc.stencilAttachment.storeAction = MTLStoreActionStore;
            desc.stencilAttachment.clearStencil = clear.value.stencil;
        }
    } else {
        const auto& color = clear.value.color;
        desc.colorAttachments[0].texture = texture;
        desc.colorAttachments[0].level = clear.texture_level;
        desc.colorAttachments[0].slice = clear.texture_layer;
        desc.colorAttachments[0].loadAction = MTLLoadActionClear;
        desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        desc.colorAttachments[0].clearColor = MTLClearColorMake(color.x, color.y, color.z, color.w);
    }
    scheduler.BeginRendering(desc);
    scheduler.EndEncoding();
    return true;
}

bool TextureRuntime::CopyTextures(Surface& source, Surface& dest,
                                  std::span<const VideoCore::TextureCopy> copies) {
    id<MTLTexture> src = source.Texture();
    id<MTLTexture> dst = dest.Texture();
    if (!src || !dst) {
        return false;
    }
    if (src.pixelFormat != dst.pixelFormat) {
        LOG_ERROR(Render, "Attempted copy between incompatible formats {} -> {}",
                  VideoCore::PixelFormatAsString(source.pixel_format),
                  VideoCore::PixelFormatAsString(dest.pixel_format));
        return false;
    }

    id<MTLBlitCommandEncoder> blit = scheduler.BlitEncoder();
    for (const auto& copy : copies) {
        const auto [src_w, src_h] = LevelExtent(src, copy.src_level);
        const auto [dst_w, dst_h] = LevelExtent(dst, copy.dst_level);
        if (copy.src_offset.x >= src_w || copy.src_offset.y >= src_h ||
            copy.dst_offset.x >= dst_w || copy.dst_offset.y >= dst_h) {
            continue;
        }
        const u32 width =
            std::min({copy.extent.width, src_w - copy.src_offset.x, dst_w - copy.dst_offset.x});
        const u32 height =
            std::min({copy.extent.height, src_h - copy.src_offset.y, dst_h - copy.dst_offset.y});
        if (width == 0 || height == 0) {
            continue;
        }
        [blit copyFromTexture:src
                  sourceSlice:copy.src_layer
                  sourceLevel:copy.src_level
                 sourceOrigin:MTLOriginMake(copy.src_offset.x, copy.src_offset.y, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                    toTexture:dst
             destinationSlice:copy.dst_layer
             destinationLevel:copy.dst_level
            destinationOrigin:MTLOriginMake(copy.dst_offset.x, copy.dst_offset.y, 0)];
    }
    return true;
}

bool TextureRuntime::BlitTextures(Surface& source, Surface& dest,
                                  const VideoCore::TextureBlit& blit) {
    id<MTLTexture> src = source.Texture();
    id<MTLTexture> dst = dest.Texture();
    if (!src || !dst) {
        return false;
    }

    const bool same_size =
        blit.src_rect.GetWidth() == blit.dst_rect.GetWidth() &&
        blit.src_rect.GetHeight() == blit.dst_rect.GetHeight() &&
        (blit.src_rect.left <= blit.src_rect.right) ==
            (blit.dst_rect.left <= blit.dst_rect.right) &&
        (blit.src_rect.bottom <= blit.src_rect.top) == (blit.dst_rect.bottom <= blit.dst_rect.top);

    if (source.IsDepth()) {
        if (same_size && src.pixelFormat == dst.pixelFormat) {
            const VideoCore::TextureCopy copy = {
                .src_level = blit.src_level,
                .dst_level = blit.dst_level,
                .src_layer = blit.src_layer,
                .dst_layer = blit.dst_layer,
                .src_offset = {std::min(blit.src_rect.left, blit.src_rect.right),
                               std::min(blit.src_rect.bottom, blit.src_rect.top)},
                .dst_offset = {std::min(blit.dst_rect.left, blit.dst_rect.right),
                               std::min(blit.dst_rect.bottom, blit.dst_rect.top)},
                .extent = {blit.src_rect.GetWidth(), blit.src_rect.GetHeight()},
            };
            return CopyTextures(source, dest, copy);
        }
        blit_helper.BlitDepthStencil(src, source.HasStencil() ? source.StencilTexture() : nil,
                                     blit.src_level, blit.src_rect, dst, blit.dst_level,
                                     blit.dst_rect);
        return true;
    }

    blit_helper.BlitColor(src, blit.src_level, blit.src_layer, blit.src_rect, dst, blit.dst_level,
                          blit.dst_layer, blit.dst_rect, true);
    return true;
}

void TextureRuntime::GenerateMipmaps(Surface& surface) {
    if (VideoCore::IsCustomFormatCompressed(surface.custom_format)) {
        LOG_ERROR(Render, "Generating mipmaps for compressed formats unsupported!");
        return;
    }
    if (surface.IsDepth() || surface.levels <= 1) {
        return;
    }
    id<MTLTexture> texture = surface.Texture();
    if (!texture || texture.mipmapLevelCount <= 1) {
        return;
    }
    [scheduler.BlitEncoder() generateMipmapsForTexture:texture];
}

// ===========================================================================================
// Surface
// ===========================================================================================

Surface::Surface(TextureRuntime& runtime_, const VideoCore::SurfaceParams& params,
                 const VideoCore::SurfaceFlagBits& initial_flag_bits)
    : SurfaceBase{params, initial_flag_bits}, runtime{&runtime_}, instance{&runtime_.GetInstance()},
      scheduler{&runtime_.GetScheduler()}, traits{instance->GetTraits(pixel_format)} {
    if (pixel_format == PixelFormat::Invalid || !traits.transfer_support) {
        return;
    }
    storage_capable = traits.native == MTLPixelFormatRGBA8Unorm;

    textures[Type::Base] = CreateTexture(width, height, traits.native, "base");
    if (res_scale != 1) {
        textures[Type::Scaled] =
            CreateTexture(GetScaledWidth(), GetScaledHeight(), traits.native, "scaled");
    }
    current = res_scale != 1 ? Type::Scaled : Type::Base;
}

Surface::Surface(TextureRuntime& runtime_, const VideoCore::SurfaceBase& surface,
                 const VideoCore::Material* mat)
    : SurfaceBase{surface}, runtime{&runtime_}, instance{&runtime_.GetInstance()},
      scheduler{&runtime_.GetScheduler()}, traits{instance->GetTraits(mat->format)} {
    if (!traits.transfer_support) {
        return;
    }

    // Set before creating the textures, the texture usage depends on it.
    custom_format = mat->format;
    material = mat;

    const bool has_normal = mat && mat->Map(MapType::Normal);
    textures[Type::Base] = CreateTexture(mat->width, mat->height, traits.native, "custom");
    if (res_scale != 1) {
        textures[Type::Scaled] =
            CreateTexture(mat->width, mat->height, MTLPixelFormatRGBA8Unorm, "custom scaled");
    }
    if (has_normal) {
        textures[Type::Custom] = CreateTexture(mat->width, mat->height, traits.native, "normal");
    }
    current = res_scale != 1 ? Type::Scaled : Type::Base;
}

Surface::~Surface() = default;

id<MTLTexture> Surface::CreateTexture(u32 tex_width, u32 tex_height, MTLPixelFormat format,
                                      std::string_view label) const {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = texture_type == TextureType::CubeMap ? MTLTextureTypeCube : MTLTextureType2D;
    desc.pixelFormat = format;
    desc.width = std::max(tex_width, 1u);
    desc.height = std::max(tex_height, 1u);
    desc.mipmapLevelCount = std::max<u32>(levels, 1u);
    desc.storageMode = MTLStorageModePrivate;

    const bool is_compressed =
        VideoCore::IsCustomFormatCompressed(custom_format) && format != MTLPixelFormatRGBA8Unorm;
    MTLTextureUsage usage = MTLTextureUsageShaderRead;
    if (!is_compressed) {
        usage |= MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    }
    if (format == MTLPixelFormatRGBA8Unorm) {
        // Allows R32Uint views for shadow mapping and texture writes for shadow rendering.
        usage |= MTLTextureUsageShaderWrite;
    }
    desc.usage = usage;

    id<MTLTexture> texture = [instance->GetDevice() newTextureWithDescriptor:desc];
    ASSERT_MSG(texture, "Failed to create {}x{} texture for {}", tex_width, tex_height,
               VideoCore::PixelFormatAsString(pixel_format));
    if (Settings::values.renderer_debug) {
        SetLabel(texture, fmt::format("Surface {:#x} {} {}x{} ({})", addr,
                                      VideoCore::PixelFormatAsString(pixel_format), tex_width,
                                      tex_height, label));
    }
    return texture;
}

id<MTLTexture> Surface::CopyTexture() {
    id<MTLTexture> src = Texture();
    __strong id<MTLTexture>& copy = textures[Type::Copy];
    if (!copy || copy.width != src.width || copy.height != src.height) {
        copy = CreateTexture(static_cast<u32>(src.width), static_cast<u32>(src.height),
                             src.pixelFormat, "copy");
    }
    [scheduler->BlitEncoder() copyFromTexture:src toTexture:copy];
    Stats().feedback_copies.fetch_add(1, std::memory_order_relaxed);
    return copy;
}

id<MTLTexture> Surface::StorageTexture() {
    id<MTLTexture> texture = Texture();
    if (!storage_capable || !texture) {
        return nil;
    }
    if (!storage_view || storage_view.parentTexture != texture) {
        storage_view = [texture newTextureViewWithPixelFormat:MTLPixelFormatR32Uint];
    }
    return storage_view;
}

id<MTLTexture> Surface::StencilTexture() {
    id<MTLTexture> texture = Texture();
    if (!traits.has_stencil || !texture) {
        return nil;
    }
    if (!stencil_view || stencil_view.parentTexture != texture) {
        stencil_view = [texture newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    }
    return stencil_view;
}

void Surface::Upload(const VideoCore::BufferTextureCopy& upload,
                     const VideoCore::StagingData& staging) {
    id<MTLTexture> texture = Texture(Type::Base);
    if (!texture) {
        return;
    }

    const auto& rect = upload.texture_rect;
    const u32 rect_width = rect.GetWidth();
    const u32 rect_height = rect.GetHeight();
    const MTLOrigin origin = MTLOriginMake(rect.left, std::min(rect.bottom, rect.top), 0);
    const MTLSize size = MTLSizeMake(rect_width, rect_height, 1);
    id<MTLBuffer> buffer = runtime->upload_buffer.Handle();

    if (traits.has_stencil) {
        // De-interleave the (D24 << 8 | S8) words into a float depth plane and a stencil plane.
        const u32 num_pixels = rect_width * rect_height;
        u8* data = staging.mapped.data();
        for (u32 i = 0; i < num_pixels; i++) {
            u32 value;
            std::memcpy(&value, data + i * 4, sizeof(value));
            const f32 depth = static_cast<f32>(value >> 8) / 16777215.0f;
            std::memcpy(data + i * 4, &depth, sizeof(depth));
            data[num_pixels * 4 + i] = static_cast<u8>(value & 0xFF);
        }

        id<MTLBlitCommandEncoder> blit = scheduler->BlitEncoder();
        [blit copyFromBuffer:buffer
                   sourceOffset:upload.buffer_offset
              sourceBytesPerRow:rect_width * 4
            sourceBytesPerImage:num_pixels * 4
                     sourceSize:size
                      toTexture:texture
               destinationSlice:0
               destinationLevel:upload.texture_level
              destinationOrigin:origin
                        options:MTLBlitOptionDepthFromDepthStencil];
        [blit copyFromBuffer:buffer
                   sourceOffset:upload.buffer_offset + num_pixels * 4
              sourceBytesPerRow:rect_width
            sourceBytesPerImage:num_pixels
                     sourceSize:size
                      toTexture:texture
               destinationSlice:0
               destinationLevel:upload.texture_level
              destinationOrigin:origin
                        options:MTLBlitOptionStencilFromDepthStencil];
    } else {
        const u32 bpp = GetInternalBytesPerPixel();
        [scheduler->BlitEncoder() copyFromBuffer:buffer
                                    sourceOffset:upload.buffer_offset
                               sourceBytesPerRow:rect_width * bpp
                             sourceBytesPerImage:rect_width * rect_height * bpp
                                      sourceSize:size
                                       toTexture:texture
                                destinationSlice:0
                                destinationLevel:upload.texture_level
                               destinationOrigin:origin];
    }

    runtime->upload_buffer.Commit(staging.size);

    if (res_scale != 1) {
        ASSERT_MSG(textures[Type::Scaled], "Scaled allocation missing during upload");
        const VideoCore::TextureBlit blit = {
            .src_level = upload.texture_level,
            .dst_level = upload.texture_level,
            .src_rect = upload.texture_rect,
            .dst_rect = upload.texture_rect * res_scale,
        };
        BlitScale(blit, true);
    }
}

void Surface::UploadCustom(const VideoCore::Material* custom_material, u32 level) {
    const u32 mat_width = std::max(custom_material->width >> level, 1u);
    const u32 mat_height = std::max(custom_material->height >> level, 1u);

    const auto upload = [&](Type type, VideoCore::CustomTexture* texture) {
        id<MTLTexture> target = textures[type];
        if (!target || !texture) {
            return;
        }
        const u32 custom_size = static_cast<u32>(texture->data.size());
        const auto [data, offset, invalidate] = runtime->upload_buffer.Map(custom_size, 16);
        std::memcpy(data, texture->data.data(), custom_size);
        runtime->upload_buffer.Commit(custom_size);

        const auto [bytes_per_row, rows] = CustomLayout(custom_format, mat_width, mat_height);
        [scheduler->BlitEncoder() copyFromBuffer:runtime->upload_buffer.Handle()
                                    sourceOffset:offset
                               sourceBytesPerRow:bytes_per_row
                             sourceBytesPerImage:bytes_per_row * rows
                                      sourceSize:MTLSizeMake(mat_width, mat_height, 1)
                                       toTexture:target
                                destinationSlice:0
                                destinationLevel:level
                               destinationOrigin:MTLOriginMake(0, 0, 0)];
    };

    upload(Type::Base, custom_material->textures[0]);
    if (auto* texture = custom_material->textures[static_cast<u32>(MapType::Normal)]) {
        upload(Type::Custom, texture);
    }
}

void Surface::Download(const VideoCore::BufferTextureCopy& download,
                       const VideoCore::StagingData& staging) {
    if (res_scale != 1) {
        const VideoCore::TextureBlit blit = {
            .src_level = download.texture_level,
            .dst_level = download.texture_level,
            .src_rect = download.texture_rect * res_scale,
            .dst_rect = download.texture_rect,
        };
        BlitScale(blit, false);
    }

    id<MTLTexture> texture = Texture(Type::Base);
    if (!texture) {
        runtime->download_buffer.Commit(staging.size);
        return;
    }

    const auto& rect = download.texture_rect;
    const u32 rect_width = rect.GetWidth();
    const u32 rect_height = rect.GetHeight();
    const u32 num_pixels = rect_width * rect_height;
    const MTLOrigin origin = MTLOriginMake(rect.left, std::min(rect.bottom, rect.top), 0);
    const MTLSize size = MTLSizeMake(rect_width, rect_height, 1);
    id<MTLBuffer> buffer = runtime->download_buffer.Handle();

    id<MTLBlitCommandEncoder> blit = scheduler->BlitEncoder();
    if (traits.has_stencil) {
        [blit copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:download.texture_level
                        sourceOrigin:origin
                          sourceSize:size
                            toBuffer:buffer
                   destinationOffset:download.buffer_offset
              destinationBytesPerRow:rect_width * 4
            destinationBytesPerImage:num_pixels * 4
                             options:MTLBlitOptionDepthFromDepthStencil];
        [blit copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:download.texture_level
                        sourceOrigin:origin
                          sourceSize:size
                            toBuffer:buffer
                   destinationOffset:download.buffer_offset + num_pixels * 4
              destinationBytesPerRow:rect_width
            destinationBytesPerImage:num_pixels
                             options:MTLBlitOptionStencilFromDepthStencil];
    } else {
        const u32 bpp = GetInternalBytesPerPixel();
        [blit copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:download.texture_level
                        sourceOrigin:origin
                          sourceSize:size
                            toBuffer:buffer
                   destinationOffset:download.buffer_offset
              destinationBytesPerRow:rect_width * bpp
            destinationBytesPerImage:num_pixels * bpp];
    }

    // The rasterizer cache reads the staging memory right after this returns.
    scheduler->Finish();

    if (traits.has_stencil) {
        // Interleave back into (D24 << 8 | S8) words, which the codec then rotates.
        u8* data = staging.mapped.data();
        for (u32 i = 0; i < num_pixels; i++) {
            f32 depth;
            std::memcpy(&depth, data + i * 4, sizeof(depth));
            const u32 d24 = static_cast<u32>(std::clamp(depth, 0.0f, 1.0f) * 16777215.0f);
            const u32 value = (d24 << 8) | data[num_pixels * 4 + i];
            std::memcpy(data + i * 4, &value, sizeof(value));
        }
    }

    runtime->download_buffer.Commit(staging.size);
}

void Surface::ScaleUp(u32 new_scale) {
    if (res_scale == new_scale || new_scale == 1) {
        return;
    }

    res_scale = new_scale;
    textures[Type::Scaled] =
        CreateTexture(GetScaledWidth(), GetScaledHeight(), traits.native, "scaled");
    textures[Type::Copy] = nil;
    storage_view = nil;
    stencil_view = nil;
    current = Type::Scaled;

    for (u32 level = 0; level < levels; level++) {
        const VideoCore::TextureBlit blit = {
            .src_level = level,
            .dst_level = level,
            .src_rect = GetRect(level),
            .dst_rect = GetScaledRect(level),
        };
        BlitScale(blit, true);
    }
}

void Surface::BlitScale(const VideoCore::TextureBlit& blit, bool up_scale) {
    id<MTLTexture> src = up_scale ? textures[Type::Base] : textures[Type::Scaled];
    id<MTLTexture> dst = up_scale ? textures[Type::Scaled] : textures[Type::Base];
    if (!src || !dst) {
        return;
    }

    auto& helper = runtime->GetBlitHelper();
    if (traits.is_depth) {
        id<MTLTexture> stencil = nil;
        if (traits.has_stencil) {
            stencil = [src newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
        }
        helper.BlitDepthStencil(src, stencil, blit.src_level, blit.src_rect, dst, blit.dst_level,
                                blit.dst_rect);
        return;
    }

    const u32 slices = texture_type == TextureType::CubeMap ? 6 : 1;
    for (u32 slice = 0; slice < slices; slice++) {
        helper.BlitColor(src, blit.src_level, slice, blit.src_rect, dst, blit.dst_level, slice,
                         blit.dst_rect, true);
    }
}

u32 Surface::GetInternalBytesPerPixel() const {
    return traits.bytes_per_pixel;
}

// ===========================================================================================
// Framebuffer
// ===========================================================================================

Framebuffer::Framebuffer(TextureRuntime& runtime, const VideoCore::FramebufferParams& params,
                         Surface* color, Surface* depth)
    : VideoCore::FramebufferParams{params},
      res_scale{color ? color->res_scale : (depth ? depth->res_scale : 1u)} {
    width = height = std::numeric_limits<u32>::max();

    const auto level_extent = [](Surface* surface, u32 level) {
        const auto extent = surface->RealExtent();
        return std::make_pair(std::max(extent.width >> level, 1u),
                              std::max(extent.height >> level, 1u));
    };

    if (shadow_rendering) {
        if (!color) {
            return;
        }
        // Shadow rendering writes into the color surface through an R32Uint image without any
        // attachment bound.
        const auto [w, h] = level_extent(color, color_level);
        width = w;
        height = h;
        formats[0] = color->pixel_format;
        shadow_buffer = color->StorageTexture();
        target = RenderTarget{.width = width, .height = height};
        valid = shadow_buffer != nil;
        return;
    }

    if (color) {
        const auto [w, h] = level_extent(color, color_level);
        width = std::min(width, w);
        height = std::min(height, h);
        formats[0] = color->pixel_format;
        attachments[0] = color->Texture();
        target.color = attachments[0];
        target.color_level = color_level;
    }
    if (depth) {
        const auto [w, h] = level_extent(depth, depth_level);
        width = std::min(width, w);
        height = std::min(height, h);
        formats[1] = depth->pixel_format;
        attachments[1] = depth->Texture();
        target.depth = attachments[1];
        target.depth_level = depth_level;
        target.has_stencil = depth->HasStencil();
    }

    if (!color && !depth) {
        width = height = 0;
        return;
    }
    target.width = width;
    target.height = height;
    valid = attachments[0] != nil || attachments[1] != nil;
}

Framebuffer::~Framebuffer() = default;

// ===========================================================================================
// Sampler
// ===========================================================================================

Sampler::Sampler(TextureRuntime& runtime, const VideoCore::SamplerParams& params) {
    using TextureConfig = VideoCore::SamplerParams::TextureConfig;

    MTLSamplerDescriptor* desc = [MTLSamplerDescriptor new];
    desc.magFilter = PicaToMTL::TextureFilterMode(params.mag_filter);
    desc.minFilter = PicaToMTL::TextureFilterMode(params.min_filter);
    desc.mipFilter = PicaToMTL::TextureMipFilterMode(params.mip_filter);
    desc.sAddressMode = PicaToMTL::WrapModeToMTL(params.wrap_s);
    desc.tAddressMode = PicaToMTL::WrapModeToMTL(params.wrap_t);
    desc.rAddressMode = MTLSamplerAddressModeClampToEdge;
    desc.lodMinClamp = static_cast<float>(params.lod_min);
    desc.lodMaxClamp = static_cast<float>(params.lod_max);

    // Anisotropic filtering only applies when linear filtering is used everywhere.
    const bool use_anisotropy = params.mag_filter == TextureConfig::TextureFilter::Linear &&
                                params.min_filter == TextureConfig::TextureFilter::Linear;
    desc.maxAnisotropy =
        use_anisotropy ? static_cast<NSUInteger>(std::clamp(GetQualityOptions().max_anisotropy, 1, 16))
                       : 1;

    sampler = [runtime.GetInstance().GetDevice() newSamplerStateWithDescriptor:desc];
}

Sampler::~Sampler() = default;

// ===========================================================================================
// DebugScope
// ===========================================================================================

DebugScope::DebugScope(TextureRuntime& runtime, Common::Vec4f, std::string_view label)
    : scheduler{runtime.GetScheduler()}, enabled{Settings::values.renderer_debug.GetValue()} {
    if (enabled) {
        scheduler.PushDebugGroup(label);
    }
}

DebugScope::~DebugScope() {
    if (enabled) {
        scheduler.PopDebugGroup();
    }
}

} // namespace Metal
