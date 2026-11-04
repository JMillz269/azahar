// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <string_view>

// Metal Shading Language sources of the fixed utility programs used by the Metal renderer. Kept
// in a plain C++ header so they can be validated offline by CI (see tests/msl_corpus.cpp).

namespace Metal::Shaders {

/// Blits, partial clears and format reinterpretation.
constexpr std::string_view UTILITY = R"(
#include <metal_stdlib>
using namespace metal;

struct BlitParams {
    float4 src_rect; // Source coordinates (x0, y0, x1, y1) of the destination corners.
    float4 color;
    float depth;
    float lod;
    float2 pad;
};

struct BlitVOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitVOut blit_vs(uint vid [[vertex_id]], constant BlitParams& p [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    BlitVOut o;
    // corner (0, 0) is the top-left of the viewport.
    o.position = float4(corner.x * 2.0f - 1.0f, 1.0f - corner.y * 2.0f, 0.0f, 1.0f);
    o.uv = mix(p.src_rect.xy, p.src_rect.zw, corner);
    return o;
}

fragment float4 blit_color_fs(BlitVOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    return src.sample(s, in.uv, level(0.0f));
}

struct DepthOut {
    float depth [[depth(any)]];
};

fragment DepthOut blit_depth_fs(BlitVOut in [[stage_in]], depth2d<float> src [[texture(0)]],
                                sampler s [[sampler(0)]]) {
    DepthOut o;
    o.depth = src.sample(s, in.uv, level(0.0f));
    return o;
}

fragment float4 clear_color_fs(constant BlitParams& p [[buffer(0)]]) {
    return p.color;
}

fragment DepthOut clear_depth_fs(constant BlitParams& p [[buffer(0)]]) {
    DepthOut o;
    o.depth = p.depth;
    return o;
}

// Reinterprets a D24S8 depth-stencil surface as RGBA8, matching the Vulkan backend's compute
// shader. src_rect.xy holds the offset to add to the destination pixel to get the source pixel.
fragment float4 d24s8_to_rgba8_fs(BlitVOut in [[stage_in]], depth2d<float> depth [[texture(0)]],
                                  texture2d<uint> stencil [[texture(1)]],
                                  constant BlitParams& p [[buffer(0)]]) {
    uint2 coord = uint2(int2(in.position.xy) + int2(p.src_rect.xy));
    uint depth_val = uint(depth.read(coord) * (exp2(32.0f) - 1.0f));
    uint stencil_val = stencil.read(coord).x;
    uint4 components = uint4(stencil_val, (uint3(depth_val) >> uint3(24u, 16u, 8u)) & 0xFFu);
    return float4(components) / 255.0f;
}
)";

/// Depth-stencil blits, requires stencil export support ([[stencil]]).
constexpr std::string_view STENCIL = R"(
#include <metal_stdlib>
using namespace metal;

struct BlitVOut {
    float4 position [[position]];
    float2 uv;
};

struct BlitParams {
    float4 src_rect;
    float4 color;
    float depth;
    float lod;
    float2 pad;
};

struct DepthStencilOut {
    float depth [[depth(any)]];
    uint stencil [[stencil]];
};

fragment DepthStencilOut blit_depth_stencil_fs(BlitVOut in [[stage_in]],
                                               depth2d<float> src [[texture(0)]],
                                               texture2d<uint> stencil [[texture(1)]],
                                               sampler s [[sampler(0)]]) {
    DepthStencilOut o;
    o.depth = src.sample(s, in.uv, level(0.0f));
    uint2 size = uint2(stencil.get_width(), stencil.get_height());
    uint2 coord = min(uint2(clamp(in.uv, 0.0f, 1.0f) * float2(size)), size - 1u);
    o.stencil = stencil.read(coord).x;
    return o;
}
)";

/// Presentation of the 3DS screens to the CAMetalLayer.
constexpr std::string_view PRESENT = R"(
#include <metal_stdlib>
using namespace metal;

struct PresentUniforms {
    float4 o_resolution; // layout width, height, 1/width, 1/height
    float4 fill_color;
    int use_fill;
    int pad0;
    int pad1;
    int pad2;
};

struct PresentVertex {
    float2 position;
    float2 tex_coord;
};

struct PresentVOut {
    float4 position [[position]];
    float2 tex_coord;
};

vertex PresentVOut present_vs(uint vid [[vertex_id]],
                              constant PresentVertex* vertices [[buffer(0)]],
                              constant PresentUniforms& u [[buffer(1)]]) {
    PresentVOut o;
    float2 pos = vertices[vid].position;
    // Layout coordinates have the origin at the top-left corner and +Y pointing down.
    o.position = float4(pos.x * 2.0f * u.o_resolution.z - 1.0f,
                        1.0f - pos.y * 2.0f * u.o_resolution.w, 0.0f, 1.0f);
    o.tex_coord = vertices[vid].tex_coord;
    return o;
}

fragment float4 present_fs(PresentVOut in [[stage_in]], texture2d<float> screen [[texture(0)]],
                           sampler s [[sampler(0)]], constant PresentUniforms& u [[buffer(1)]]) {
    if (u.use_fill != 0) {
        return u.fill_color;
    }
    return float4(screen.sample(s, in.tex_coord).rgb, 1.0f);
}
)";

} // namespace Metal::Shaders
