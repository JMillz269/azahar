// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <array>
#include "common/assert.h"
#include "common/logging/log.h"
#include "common/vector_math.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/renderer_metal/mtl_common.h"

namespace PicaToMTL {

using TextureFilter = Pica::TexturingRegs::TextureConfig::TextureFilter;
using WrapMode = Pica::TexturingRegs::TextureConfig::WrapMode;

inline MTLSamplerMinMagFilter TextureFilterMode(TextureFilter mode) {
    return mode == TextureFilter::Nearest ? MTLSamplerMinMagFilterNearest
                                          : MTLSamplerMinMagFilterLinear;
}

inline MTLSamplerMipFilter TextureMipFilterMode(TextureFilter mode) {
    return mode == TextureFilter::Nearest ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
}

/// Metal has no custom border colors, ClampToBorder is emulated in the fragment shader (see
/// TextureConfig::ApplyProfile) so it maps to ClampToEdge here.
inline MTLSamplerAddressMode WrapModeToMTL(WrapMode mode) {
    static constexpr std::array<MTLSamplerAddressMode, 8> wrap_mode_table{{
        MTLSamplerAddressModeClampToEdge,
        MTLSamplerAddressModeClampToEdge,
        MTLSamplerAddressModeRepeat,
        MTLSamplerAddressModeMirrorRepeat,
        // TODO(wwylele): ClampToEdge2 and ClampToBorder2 are not properly implemented here. See the
        // comments in enum WrapMode.
        MTLSamplerAddressModeClampToEdge,
        MTLSamplerAddressModeClampToEdge,
        MTLSamplerAddressModeRepeat,
        MTLSamplerAddressModeRepeat,
    }};
    const auto index = static_cast<std::size_t>(mode);
    ASSERT_MSG(index < wrap_mode_table.size(), "Unknown texture wrap mode {}", index);
    return wrap_mode_table[index];
}

inline MTLBlendOperation BlendEquation(Pica::FramebufferRegs::BlendEquation equation) {
    static constexpr std::array<MTLBlendOperation, 5> blend_equation_table{{
        MTLBlendOperationAdd,
        MTLBlendOperationSubtract,
        MTLBlendOperationReverseSubtract,
        MTLBlendOperationMin,
        MTLBlendOperationMax,
    }};
    const auto index = static_cast<std::size_t>(equation);
    if (index >= blend_equation_table.size()) {
        LOG_CRITICAL(Render, "Unknown blend equation {}", index);
        // This return value is hwtested, not just a stub
        return MTLBlendOperationAdd;
    }
    return blend_equation_table[index];
}

inline MTLBlendFactor BlendFunc(Pica::FramebufferRegs::BlendFactor factor) {
    static constexpr std::array<MTLBlendFactor, 15> blend_func_table{{
        MTLBlendFactorZero,                     // BlendFactor::Zero
        MTLBlendFactorOne,                      // BlendFactor::One
        MTLBlendFactorSourceColor,              // BlendFactor::SourceColor
        MTLBlendFactorOneMinusSourceColor,      // BlendFactor::OneMinusSourceColor
        MTLBlendFactorDestinationColor,         // BlendFactor::DestColor
        MTLBlendFactorOneMinusDestinationColor, // BlendFactor::OneMinusDestColor
        MTLBlendFactorSourceAlpha,              // BlendFactor::SourceAlpha
        MTLBlendFactorOneMinusSourceAlpha,      // BlendFactor::OneMinusSourceAlpha
        MTLBlendFactorDestinationAlpha,         // BlendFactor::DestAlpha
        MTLBlendFactorOneMinusDestinationAlpha, // BlendFactor::OneMinusDestAlpha
        MTLBlendFactorBlendColor,               // BlendFactor::ConstantColor
        MTLBlendFactorOneMinusBlendColor,       // BlendFactor::OneMinusConstantColor
        MTLBlendFactorBlendAlpha,               // BlendFactor::ConstantAlpha
        MTLBlendFactorOneMinusBlendAlpha,       // BlendFactor::OneMinusConstantAlpha
        MTLBlendFactorSourceAlphaSaturated,     // BlendFactor::SourceAlphaSaturate
    }};
    const auto index = static_cast<std::size_t>(factor);
    if (index >= blend_func_table.size()) {
        LOG_CRITICAL(Render, "Unknown blend factor {}", index);
        return MTLBlendFactorOne;
    }
    return blend_func_table[index];
}

inline MTLCompareFunction CompareFunc(Pica::FramebufferRegs::CompareFunc func) {
    static constexpr std::array<MTLCompareFunction, 8> compare_func_table{{
        MTLCompareFunctionNever,        // CompareFunc::Never
        MTLCompareFunctionAlways,       // CompareFunc::Always
        MTLCompareFunctionEqual,        // CompareFunc::Equal
        MTLCompareFunctionNotEqual,     // CompareFunc::NotEqual
        MTLCompareFunctionLess,         // CompareFunc::LessThan
        MTLCompareFunctionLessEqual,    // CompareFunc::LessThanOrEqual
        MTLCompareFunctionGreater,      // CompareFunc::GreaterThan
        MTLCompareFunctionGreaterEqual, // CompareFunc::GreaterThanOrEqual
    }};
    const auto index = static_cast<std::size_t>(func);
    ASSERT_MSG(index < compare_func_table.size(), "Unknown compare function {}", index);
    return compare_func_table[index];
}

inline MTLStencilOperation StencilOp(Pica::FramebufferRegs::StencilAction action) {
    static constexpr std::array<MTLStencilOperation, 8> stencil_op_table{{
        MTLStencilOperationKeep,           // StencilAction::Keep
        MTLStencilOperationZero,           // StencilAction::Zero
        MTLStencilOperationReplace,        // StencilAction::Replace
        MTLStencilOperationIncrementClamp, // StencilAction::Increment
        MTLStencilOperationDecrementClamp, // StencilAction::Decrement
        MTLStencilOperationInvert,         // StencilAction::Invert
        MTLStencilOperationIncrementWrap,  // StencilAction::IncrementWrap
        MTLStencilOperationDecrementWrap,  // StencilAction::DecrementWrap
    }};
    const auto index = static_cast<std::size_t>(action);
    ASSERT_MSG(index < stencil_op_table.size(), "Unknown stencil op {}", index);
    return stencil_op_table[index];
}

/// Mirrors PicaToVK::CullMode/FrontFace. Metal evaluates the winding in framebuffer coordinates
/// like Vulkan, and our vertex shader produces the exact same framebuffer image as Vulkan's.
inline MTLCullMode CullMode(Pica::RasterizerRegs::CullMode mode, bool flip_viewport) {
    switch (mode) {
    case Pica::RasterizerRegs::CullMode::KeepAll:
    case Pica::RasterizerRegs::CullMode::KeepAll2:
        return MTLCullModeNone;
    case Pica::RasterizerRegs::CullMode::KeepClockWise:
    case Pica::RasterizerRegs::CullMode::KeepCounterClockWise:
        return flip_viewport ? MTLCullModeFront : MTLCullModeBack;
    default:
        LOG_CRITICAL(Render, "Unknown cull mode {}", mode);
        return MTLCullModeNone;
    }
}

inline MTLWinding FrontFace(Pica::RasterizerRegs::CullMode mode) {
    switch (mode) {
    case Pica::RasterizerRegs::CullMode::KeepCounterClockWise:
        return MTLWindingClockwise;
    default:
        return MTLWindingCounterClockwise;
    }
}

inline Common::Vec4f ColorRGBA8(const u32 color) {
    const auto rgba =
        Common::Vec4u{color >> 0 & 0xFF, color >> 8 & 0xFF, color >> 16 & 0xFF, color >> 24 & 0xFF};
    return rgba / 255.0f;
}

} // namespace PicaToMTL
