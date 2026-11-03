// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <array>
#include <cstring>
#include "common/assert.h"
#include "common/logging/log.h"
#include "common/microprofile.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/emu_window.h"
#include "core/frontend/framebuffer_layout.h"
#include "core/perf_stats.h"
#include "video_core/gpu.h"
#include "video_core/pica/pica_core.h"
#include "video_core/renderer_base.h"
#include "video_core/renderer_metal/mtl_instance.h"
#include "video_core/renderer_metal/mtl_rasterizer.h"
#include "video_core/renderer_metal/mtl_scheduler.h"
#include "video_core/renderer_metal/mtl_utility_shaders.h"
#include "video_core/renderer_metal/renderer_metal.h"

MICROPROFILE_DEFINE(Metal_RenderFrame, "Metal", "Render Frame", MP_RGB(128, 128, 64));

namespace Metal {

namespace {

struct ScreenRectVertex {
    ScreenRectVertex() = default;
    ScreenRectVertex(float x, float y, float u, float v) : position{x, y}, tex_coord{u, v} {}

    std::array<f32, 2> position{};
    std::array<f32, 2> tex_coord{};
};

struct PresentUniforms {
    std::array<f32, 4> o_resolution;
    std::array<f32, 4> fill_color;
    s32 use_fill;
    s32 pad[3];
};
static_assert(sizeof(PresentUniforms) == 48);

class RendererMetal final : public VideoCore::RendererBase {
public:
    explicit RendererMetal(Core::System& system, Pica::PicaCore& pica_, Frontend::EmuWindow& window,
                           Frontend::EmuWindow* secondary_window)
        : RendererBase{system, window, secondary_window}, pica{pica_}, scheduler{instance},
          rasterizer{system.Memory(), pica_,    system.CustomTexManager(),
                     *this,           instance, scheduler} {
        CompilePresentPipelines();
        AcquireLayer();
    }

    ~RendererMetal() override {
        scheduler.Finish();
    }

    [[nodiscard]] VideoCore::RasterizerInterface* Rasterizer() override {
        return &rasterizer;
    }

    void NotifySurfaceChanged(bool second) override {
        if (!second) {
            layer_dirty = true;
        }
    }

    void SwapBuffers() override;

    void TryPresent(int timeout_ms, bool is_secondary) override {}

private:
    void CompilePresentPipelines();
    void AcquireLayer();
    void PrepareRendertarget();
    void LoadFBToScreenInfo(const Pica::FramebufferConfig& framebuffer, ScreenInfo& screen_info,
                            bool right_eye);
    void RenderToLayer(const Layout::FramebufferLayout& layout);
    void RenderScreenshot();
    void DrawScreens(id<MTLRenderCommandEncoder> encoder, const Layout::FramebufferLayout& layout);
    void DrawTopScreen(id<MTLRenderCommandEncoder> encoder, const Layout::FramebufferLayout& layout,
                       const Common::Rectangle<u32>& top_screen);
    void DrawBottomScreen(id<MTLRenderCommandEncoder> encoder,
                          const Layout::FramebufferLayout& layout,
                          const Common::Rectangle<u32>& bottom_screen);
    void DrawSingleScreen(id<MTLRenderCommandEncoder> encoder, u32 screen_id, float x, float y,
                          float w, float h, Layout::DisplayOrientation orientation);
    void SetOpacity(id<MTLRenderCommandEncoder> encoder, float alpha);
    void LimitFramesAheadOfGpu();

private:
    Pica::PicaCore& pica;
    Instance instance;
    Scheduler scheduler;
    RasterizerMetal rasterizer;

    CAMetalLayer* layer = nil;
    bool layer_dirty{};

    id<MTLRenderPipelineState> present_pipeline = nil;
    id<MTLRenderPipelineState> screenshot_pipeline = nil;
    std::array<id<MTLSamplerState>, 2> present_samplers{};

    std::array<ScreenInfo, 3> screen_infos{};
    std::array<std::array<f32, 4>, 3> fill_colors{};
    std::array<bool, 3> use_fill{};
    std::array<f32, 4> o_resolution{};
    u64 previous_frame_tick{};
};

void RendererMetal::CompilePresentPipelines() {
    id<MTLDevice> device = instance.GetDevice();
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:ToNSString(Shaders::PRESENT)
                                                  options:[MTLCompileOptions new]
                                                    error:&error];
    ASSERT_MSG(library, "Failed to compile Metal present shaders: {}",
               error ? [error.localizedDescription UTF8String] : "unknown error");

    const auto make_pipeline = [&](MTLPixelFormat format) {
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"present_vs"];
        desc.fragmentFunction = [library newFunctionWithName:@"present_fs"];
        MTLRenderPipelineColorAttachmentDescriptor* color = desc.colorAttachments[0];
        color.pixelFormat = format;
        // The second layer (e.g. a translucent bottom screen) is blended using the blend color.
        color.blendingEnabled = YES;
        color.rgbBlendOperation = MTLBlendOperationAdd;
        color.alphaBlendOperation = MTLBlendOperationAdd;
        color.sourceRGBBlendFactor = MTLBlendFactorBlendAlpha;
        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusBlendAlpha;
        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        NSError* pipeline_error = nil;
        id<MTLRenderPipelineState> pipeline =
            [device newRenderPipelineStateWithDescriptor:desc error:&pipeline_error];
        ASSERT_MSG(pipeline, "Failed to create Metal present pipeline: {}",
                   pipeline_error ? [pipeline_error.localizedDescription UTF8String] : "unknown");
        return pipeline;
    };
    present_pipeline = make_pipeline(MTLPixelFormatBGRA8Unorm);
    screenshot_pipeline = make_pipeline(MTLPixelFormatBGRA8Unorm);

    MTLSamplerDescriptor* sampler_desc = [MTLSamplerDescriptor new];
    sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_desc.minFilter = MTLSamplerMinMagFilterLinear;
    sampler_desc.magFilter = MTLSamplerMinMagFilterLinear;
    present_samplers[0] = [device newSamplerStateWithDescriptor:sampler_desc];
    sampler_desc.minFilter = MTLSamplerMinMagFilterNearest;
    sampler_desc.magFilter = MTLSamplerMinMagFilterNearest;
    present_samplers[1] = [device newSamplerStateWithDescriptor:sampler_desc];
}

void RendererMetal::AcquireLayer() {
    layer_dirty = false;
    void* surface = render_window.GetWindowInfo().render_surface;
    if (!surface) {
        layer = nil;
        LOG_WARNING(Render, "No render surface provided, the Metal renderer runs headless");
        return;
    }
    layer = (__bridge CAMetalLayer*)surface;
    layer.device = instance.GetDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.maximumDrawableCount = 3;
}

void RendererMetal::PrepareRendertarget() {
    const auto& framebuffer_config = pica.regs.framebuffer_config;
    const auto& regs_lcd = pica.regs_lcd;
    for (u32 i = 0; i < 3; i++) {
        const u32 fb_id = i == 2 ? 1 : 0;
        const auto& framebuffer = framebuffer_config[fb_id];

        const auto color_fill = fb_id == 0 ? regs_lcd.color_fill_top : regs_lcd.color_fill_bottom;
        if (color_fill.is_enabled) {
            const auto color = color_fill.AsVector();
            fill_colors[i] = {color.r() / 255.0f, color.g() / 255.0f, color.b() / 255.0f, 1.0f};
            use_fill[i] = true;
            continue;
        }
        use_fill[i] = false;
        LoadFBToScreenInfo(framebuffer, screen_infos[i], i == 1);
    }
}

void RendererMetal::LoadFBToScreenInfo(const Pica::FramebufferConfig& framebuffer,
                                       ScreenInfo& screen_info, bool right_eye) {
    if (framebuffer.address_right1 == 0 || framebuffer.address_right2 == 0) {
        right_eye = false;
    }

    const PAddr framebuffer_addr =
        framebuffer.active_fb == 0
            ? (right_eye ? framebuffer.address_right1 : framebuffer.address_left1)
            : (right_eye ? framebuffer.address_right2 : framebuffer.address_left2);

    const u32 bpp = Pica::BytesPerPixel(framebuffer.color_format);
    const std::size_t pixel_stride = framebuffer.stride / bpp;
    if (pixel_stride * bpp != framebuffer.stride || pixel_stride % 4 != 0) {
        LOG_ERROR(Render, "Unsupported framebuffer stride {}", framebuffer.stride);
        return;
    }

    if (!rasterizer.AccelerateDisplay(framebuffer, framebuffer_addr, static_cast<u32>(pixel_stride),
                                      screen_info)) {
        // Keep presenting the previous texture of this screen.
        LOG_DEBUG(Render, "Unable to display framebuffer at {:#010x}", framebuffer_addr);
    }
}

void RendererMetal::SetOpacity(id<MTLRenderCommandEncoder> encoder, float alpha) {
    [encoder setBlendColorRed:0.0f green:0.0f blue:0.0f alpha:alpha];
}

void RendererMetal::DrawSingleScreen(id<MTLRenderCommandEncoder> encoder, u32 screen_id, float x,
                                     float y, float w, float h,
                                     Layout::DisplayOrientation orientation) {
    const ScreenInfo& screen_info = screen_infos[screen_id];
    if (!use_fill[screen_id] && screen_info.texture == nil) {
        return;
    }
    const auto& texcoords = screen_info.texcoords;

    std::array<ScreenRectVertex, 4> vertices;
    switch (orientation) {
    case Layout::DisplayOrientation::Landscape:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x + w, y, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x, y + h, texcoords.top, texcoords.left),
            ScreenRectVertex(x + w, y + h, texcoords.top, texcoords.right),
        }};
        break;
    case Layout::DisplayOrientation::Portrait:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x + w, y, texcoords.top, texcoords.right),
            ScreenRectVertex(x, y + h, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x + w, y + h, texcoords.top, texcoords.left),
        }};
        break;
    case Layout::DisplayOrientation::LandscapeFlipped:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.top, texcoords.right),
            ScreenRectVertex(x + w, y, texcoords.top, texcoords.left),
            ScreenRectVertex(x, y + h, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x + w, y + h, texcoords.bottom, texcoords.left),
        }};
        break;
    case Layout::DisplayOrientation::PortraitFlipped:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.top, texcoords.left),
            ScreenRectVertex(x + w, y, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x, y + h, texcoords.top, texcoords.right),
            ScreenRectVertex(x + w, y + h, texcoords.bottom, texcoords.right),
        }};
        break;
    default:
        LOG_ERROR(Render, "Unknown DisplayOrientation: {}", orientation);
        return;
    }

    const PresentUniforms uniforms = {
        .o_resolution = o_resolution,
        .fill_color = fill_colors[screen_id],
        .use_fill = use_fill[screen_id] ? 1 : 0,
    };
    [encoder setVertexBytes:vertices.data()
                     length:sizeof(ScreenRectVertex) * vertices.size()
                    atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    if (screen_info.texture != nil) {
        [encoder setFragmentTexture:screen_info.texture atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

void RendererMetal::DrawTopScreen(id<MTLRenderCommandEncoder> encoder,
                                  const Layout::FramebufferLayout& layout,
                                  const Common::Rectangle<u32>& top_screen) {
    if (!layout.top_screen_enabled) {
        return;
    }
    const int leftside = Settings::values.swap_eyes_3d.GetValue() ? 1 : 0;
    const int rightside = Settings::values.swap_eyes_3d.GetValue() ? 0 : 1;
    const float left = static_cast<float>(top_screen.left);
    const float top = static_cast<float>(top_screen.top);
    const float width = static_cast<float>(top_screen.GetWidth());
    const float height = static_cast<float>(top_screen.GetHeight());

    const auto orientation = layout.is_rotated ? Layout::DisplayOrientation::Landscape
                                               : Layout::DisplayOrientation::Portrait;
    switch (layout.render_3d_mode) {
    case Settings::StereoRenderOption::SideBySide:
        DrawSingleScreen(encoder, leftside, left / 2, top, width / 2, height, orientation);
        DrawSingleScreen(encoder, rightside, (left / 2) + (layout.width / 2), top, width / 2,
                         height, orientation);
        break;
    case Settings::StereoRenderOption::SideBySideFull:
        DrawSingleScreen(encoder, leftside, left, top, width, height, orientation);
        DrawSingleScreen(encoder, rightside, left + layout.width / 2, top, width, height,
                         orientation);
        break;
    case Settings::StereoRenderOption::CardboardVR:
        DrawSingleScreen(encoder, leftside, left, top, width, height, orientation);
        DrawSingleScreen(
            encoder, rightside,
            static_cast<float>(layout.cardboard.top_screen_right_eye + (layout.width / 2)), top,
            width, height, orientation);
        break;
    case Settings::StereoRenderOption::Off:
    default: {
        // TODO: Anaglyph and interlaced stereo modes, these fall back to mono rendering.
        const int eye = layout.render_3d_mode == Settings::StereoRenderOption::Off
                            ? static_cast<int>(Settings::values.mono_render_option.GetValue())
                            : leftside;
        DrawSingleScreen(encoder, eye, left, top, width, height, orientation);
        break;
    }
    }
}

void RendererMetal::DrawBottomScreen(id<MTLRenderCommandEncoder> encoder,
                                     const Layout::FramebufferLayout& layout,
                                     const Common::Rectangle<u32>& bottom_screen) {
    if (!layout.bottom_screen_enabled) {
        return;
    }
    const float left = static_cast<float>(bottom_screen.left);
    const float top = static_cast<float>(bottom_screen.top);
    const float width = static_cast<float>(bottom_screen.GetWidth());
    const float height = static_cast<float>(bottom_screen.GetHeight());

    const auto orientation = layout.is_rotated ? Layout::DisplayOrientation::Landscape
                                               : Layout::DisplayOrientation::Portrait;
    switch (layout.render_3d_mode) {
    case Settings::StereoRenderOption::SideBySide:
        DrawSingleScreen(encoder, 2, left / 2, top, width / 2, height, orientation);
        DrawSingleScreen(encoder, 2, (left / 2) + (layout.width / 2), top, width / 2, height,
                         orientation);
        break;
    case Settings::StereoRenderOption::SideBySideFull:
        DrawSingleScreen(encoder, 2, left, top, width, height, orientation);
        DrawSingleScreen(encoder, 2, left + layout.width / 2, top, width, height, orientation);
        break;
    case Settings::StereoRenderOption::CardboardVR:
        DrawSingleScreen(encoder, 2, left, top, width, height, orientation);
        DrawSingleScreen(
            encoder, 2,
            static_cast<float>(layout.cardboard.bottom_screen_right_eye + (layout.width / 2)), top,
            width, height, orientation);
        break;
    default:
        DrawSingleScreen(encoder, 2, left, top, width, height, orientation);
        break;
    }
}

void RendererMetal::DrawScreens(id<MTLRenderCommandEncoder> encoder,
                                const Layout::FramebufferLayout& layout) {
    o_resolution = {static_cast<f32>(layout.width), static_cast<f32>(layout.height),
                    1.0f / static_cast<f32>(layout.width), 1.0f / static_cast<f32>(layout.height)};

    [encoder setRenderPipelineState:present_pipeline];
    [encoder setFragmentSamplerState:present_samplers[!Settings::values.filter_mode.GetValue()]
                             atIndex:0];
    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(layout.width),
                                     static_cast<double>(layout.height), 0.0, 1.0}];
    SetOpacity(encoder, 1.0f);

    if (!Settings::values.swap_screen.GetValue()) {
        DrawTopScreen(encoder, layout, layout.top_screen);
        if (layout.bottom_opacity < 1) {
            SetOpacity(encoder, layout.bottom_opacity);
        }
        DrawBottomScreen(encoder, layout, layout.bottom_screen);
    } else {
        DrawBottomScreen(encoder, layout, layout.bottom_screen);
        if (layout.top_opacity < 1) {
            SetOpacity(encoder, layout.top_opacity);
        }
        DrawTopScreen(encoder, layout, layout.top_screen);
    }

    if (layout.additional_screen_enabled) {
        SetOpacity(encoder, 1.0f);
        if (!layout.additional_screen_is_bottom) {
            DrawTopScreen(encoder, layout, layout.additional_screen);
        } else {
            DrawBottomScreen(encoder, layout, layout.additional_screen);
        }
    }
}

void RendererMetal::RenderToLayer(const Layout::FramebufferLayout& layout) {
    if (layer_dirty) {
        AcquireLayer();
    }
    if (layer == nil || layout.width == 0 || layout.height == 0) {
        return;
    }

    const CGSize size = CGSizeMake(layout.width, layout.height);
    if (!CGSizeEqualToSize(layer.drawableSize, size)) {
        layer.drawableSize = size;
    }

    id<CAMetalDrawable> drawable = nil;
    @autoreleasepool {
        drawable = [layer nextDrawable];
    }
    if (drawable == nil) {
        return;
    }

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor =
        MTLClearColorMake(Settings::values.bg_red.GetValue(), Settings::values.bg_green.GetValue(),
                          Settings::values.bg_blue.GetValue(), 1.0);

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    DrawScreens(encoder, layout);
    scheduler.EndEncoding();
    scheduler.PresentDrawable(drawable);
}

void RendererMetal::RenderScreenshot() {
    if (!settings.screenshot_requested.exchange(false)) {
        return;
    }

    const Layout::FramebufferLayout layout{settings.screenshot_framebuffer_layout};
    const u32 width = layout.width;
    const u32 height = layout.height;
    if (width == 0 || height == 0 || !settings.screenshot_bits) {
        if (settings.screenshot_complete_callback) {
            settings.screenshot_complete_callback(false);
        }
        return;
    }

    id<MTLDevice> device = instance.GetDevice();
    MTLTextureDescriptor* tex_desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    tex_desc.usage = MTLTextureUsageRenderTarget;
    tex_desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:tex_desc];
    id<MTLBuffer> readback = [device newBufferWithLength:width * height * 4
                                                 options:MTLResourceStorageModeShared];

    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = target;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    DrawScreens(encoder, layout);
    scheduler.EndEncoding();

    [scheduler.BlitEncoder() copyFromTexture:target
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0, 0, 0)
                                  sourceSize:MTLSizeMake(width, height, 1)
                                    toBuffer:readback
                           destinationOffset:0
                      destinationBytesPerRow:width * 4
                    destinationBytesPerImage:width * height * 4];
    scheduler.Finish();

    // QImage::Format_RGB32 and the other frontends expect BGRA byte order.
    std::memcpy(settings.screenshot_bits, readback.contents, width * height * 4);
    if (settings.screenshot_complete_callback) {
        settings.screenshot_complete_callback(true);
    }
}

void RendererMetal::LimitFramesAheadOfGpu() {
    if (previous_frame_tick != 0) {
        scheduler.Wait(previous_frame_tick);
    }
    previous_frame_tick = scheduler.CurrentTick() - 1;
}

void RendererMetal::SwapBuffers() {
    MICROPROFILE_SCOPE(Metal_RenderFrame);
    system.perf_stats->StartSwap();

    const Layout::FramebufferLayout& layout = render_window.GetFramebufferLayout();
    PrepareRendertarget();
    RenderScreenshot();

    if (!Settings::values.use_skip_duplicate_frames.GetValue() ||
        Core::PerfStats::game_frames_updated) {
        RenderToLayer(layout);
        Core::PerfStats::game_frames_updated = false;
    }

    scheduler.Flush();
    LimitFramesAheadOfGpu();

    system.perf_stats->EndSwap();
    rasterizer.TickFrame();
    EndFrame();
}

} // Anonymous namespace

std::unique_ptr<VideoCore::RendererBase> CreateRenderer(Core::System& system, Pica::PicaCore& pica,
                                                        Frontend::EmuWindow& window,
                                                        Frontend::EmuWindow* secondary_window) {
    if (secondary_window) {
        LOG_WARNING(Render, "The Metal renderer does not support secondary windows yet");
    }
    return std::make_unique<RendererMetal>(system, pica, window, secondary_window);
}

} // namespace Metal
