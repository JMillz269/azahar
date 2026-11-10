// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <array>
#include <atomic>
#include <chrono>
#include <thread>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "common/assert.h"
#include "common/file_util.h"
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

#import <QuartzCore/QuartzCore.h>

// MetalFX is weakly linked, the spatial scaler needs iOS 16 / macOS 13.
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define AZAHAR_HAS_METALFX 1
#else
#define AZAHAR_HAS_METALFX 0
#endif

MICROPROFILE_DEFINE(Metal_RenderFrame, "Metal", "Render Frame", MP_RGB(128, 128, 64));

namespace Metal {

namespace {

FrameGeneratorHooks g_fg_hooks;

/// When the frames of frame generation reach the screen. Shared with the callbacks of the
/// drawables, which can run after the renderer is gone.
struct FrameTimeline {
    /// The refresh of the display the last real frame was set to be shown at.
    std::atomic<double> real_target{0.0};
    /// When a real frame was shown (the time the display reports), and the target it had.
    std::atomic<double> real_actual{0.0};
    std::atomic<double> real_actual_for{0.0};
    /// How long before a refresh a frame has to be handed over to be shown at it. Grows a little
    /// when a frame comes too late for its refresh and shrinks again while frames are in time.
    std::atomic<double> lead{0.008};
};

/// Learns how far ahead of its refresh a frame has to be handed over. A display at 60 Hz needs
/// about a refresh more than one at 120 Hz (the compositor works a refresh ahead), so it is not
/// fixed: a frame that misses its refresh adds 2 ms, frames in time take it back slowly.
void AdjustLead(FrameTimeline& timeline, bool missed) {
    double value = timeline.lead.load(std::memory_order_relaxed);
    if (missed) {
        Stats().fg_late.fetch_add(1, std::memory_order_relaxed);
        value = std::min(value + 0.002, 0.040);
    } else {
        value = std::max(value - 0.00003, 0.004);
    }
    timeline.lead.store(value, std::memory_order_relaxed);
    Stats().fg_lead_us.store(static_cast<u32>(value * 1e6), std::memory_order_relaxed);
}

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
    s32 reverse_interlaced;
    f32 interlace_rows;
    s32 interlace_use_y;
    s32 effect;
    s32 anaglyph_mode;
    s32 pad0;
    s32 pad1;
};
static_assert(sizeof(PresentUniforms) == 64);

std::atomic<int> g_post_effect{0};
std::atomic<int> g_anaglyph_mode{0};
std::mutex g_custom_post_mutex;
std::string g_custom_post_path;

std::atomic<int> g_upscaler_mode{static_cast<int>(UpscalerMode::Off)};

/// Vertices that draw a screen texture (or the part of it given by `texcoords`) into a rectangle.
/// The 3DS framebuffers are stored rotated, the orientation takes care of that.
bool MakeScreenVertices(std::array<ScreenRectVertex, 4>& vertices,
                        const Common::Rectangle<f32>& texcoords, float x, float y, float w,
                        float h, Layout::DisplayOrientation orientation) {
    switch (orientation) {
    case Layout::DisplayOrientation::Landscape:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x + w, y, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x, y + h, texcoords.top, texcoords.left),
            ScreenRectVertex(x + w, y + h, texcoords.top, texcoords.right),
        }};
        return true;
    case Layout::DisplayOrientation::Portrait:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x + w, y, texcoords.top, texcoords.right),
            ScreenRectVertex(x, y + h, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x + w, y + h, texcoords.top, texcoords.left),
        }};
        return true;
    case Layout::DisplayOrientation::LandscapeFlipped:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.top, texcoords.right),
            ScreenRectVertex(x + w, y, texcoords.top, texcoords.left),
            ScreenRectVertex(x, y + h, texcoords.bottom, texcoords.right),
            ScreenRectVertex(x + w, y + h, texcoords.bottom, texcoords.left),
        }};
        return true;
    case Layout::DisplayOrientation::PortraitFlipped:
        vertices = {{
            ScreenRectVertex(x, y, texcoords.top, texcoords.left),
            ScreenRectVertex(x + w, y, texcoords.bottom, texcoords.left),
            ScreenRectVertex(x, y + h, texcoords.top, texcoords.right),
            ScreenRectVertex(x + w, y + h, texcoords.bottom, texcoords.right),
        }};
        return true;
    default:
        return false;
    }
}

/// Draws a texture into a rectangle of the target (in pixels) with the present pipeline, without
/// an effect and at full opacity. `width` and `height` are the size of the target.
void EncodeRect(id<MTLRenderCommandEncoder> encoder, id<MTLRenderPipelineState> pipeline,
                id<MTLSamplerState> sampler, id<MTLTexture> texture, f32 width, f32 height,
                f32 x, f32 y, f32 w, f32 h) {
    [encoder setRenderPipelineState:pipeline];
    [encoder setViewport:MTLViewport{0.0, 0.0, width, height, 0.0, 1.0}];
    [encoder setBlendColorRed:0.0f green:0.0f blue:0.0f alpha:1.0f];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    const std::array<ScreenRectVertex, 4> vertices{{
        ScreenRectVertex(x, y, 0.0f, 0.0f),
        ScreenRectVertex(x + w, y, 1.0f, 0.0f),
        ScreenRectVertex(x, y + h, 0.0f, 1.0f),
        ScreenRectVertex(x + w, y + h, 1.0f, 1.0f),
    }};
    const PresentUniforms uniforms = {
        .o_resolution = {width, height, 1.0f / width, 1.0f / height},
        .fill_color = {},
        .use_fill = 0,
        .effect = 0,
    };
    [encoder setVertexBytes:vertices.data()
                     length:sizeof(ScreenRectVertex) * vertices.size()
                    atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

/// Draws a texture over the whole target.
void EncodeFullscreen(id<MTLRenderCommandEncoder> encoder, id<MTLRenderPipelineState> pipeline,
                      id<MTLSamplerState> sampler, id<MTLTexture> texture, f32 width, f32 height) {
    EncodeRect(encoder, pipeline, sampler, texture, width, height, 0.0f, 0.0f, width, height);
}

#if AZAHAR_HAS_METALFX
/// Spatial scalers only exist on iOS 16 / macOS 13 and newer, and not on every GPU.
bool MetalFXSupported(id<MTLDevice> device) {
    if (@available(iOS 16.0, macOS 13.0, *)) {
        return NSClassFromString(@"MTLFXSpatialScalerDescriptor") != nil &&
               [MTLFXSpatialScalerDescriptor supportsDevice:device];
    }
    return false;
}
#endif

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
        // A made frame may still be on its way to the screen, its callbacks use this renderer.
        for (int i = 0; i < 200 && fg_busy.load(std::memory_order_acquire); i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    [[nodiscard]] VideoCore::RasterizerInterface* Rasterizer() override {
        return &rasterizer;
    }

    void NotifySurfaceChanged(bool second) override {
        if (second) {
            second_layer_dirty = true;
        } else {
            layer_dirty = true;
        }
    }

    void SwapBuffers() override;

    void TryPresent(int timeout_ms, bool is_secondary) override {}

private:
    void CompilePresentPipelines();
    void AcquireLayer();
    CAMetalLayer* ConfigureLayer(void* surface);
    void PrepareRendertarget();
    void LoadFBToScreenInfo(const Pica::FramebufferConfig& framebuffer, ScreenInfo& screen_info,
                            bool right_eye);
    void RenderToLayer(CAMetalLayer* target, const Layout::FramebufferLayout& layout,
                       bool allow_upscale);
    bool UseFrameGeneration(const Layout::FramebufferLayout& layout);
    void RenderGenerated(CAMetalLayer* target, const Layout::FramebufferLayout& layout);
    bool PrepareFrameGenerationResources();
    void RenderScreenshot();
    void DrawScreens(id<MTLRenderCommandEncoder> encoder, const Layout::FramebufferLayout& layout);
    void DrawTopScreen(id<MTLRenderCommandEncoder> encoder, const Layout::FramebufferLayout& layout,
                       const Common::Rectangle<u32>& top_screen);
    void DrawBottomScreen(id<MTLRenderCommandEncoder> encoder,
                          const Layout::FramebufferLayout& layout,
                          const Common::Rectangle<u32>& bottom_screen);
    void DrawSingleScreen(id<MTLRenderCommandEncoder> encoder, u32 screen_id, float x, float y,
                          float w, float h, Layout::DisplayOrientation orientation);
    void DrawSingleScreenStereo(id<MTLRenderCommandEncoder> encoder, u32 screen_id_l,
                                u32 screen_id_r, float x, float y, float w, float h,
                                Layout::DisplayOrientation orientation);
    void SetOpacity(id<MTLRenderCommandEncoder> encoder, float alpha);
    void LimitFramesAheadOfGpu();
    void DrawQuad(id<MTLRenderCommandEncoder> encoder,
                  const std::array<ScreenRectVertex, 4>& vertices, id<MTLTexture> texture,
                  const PresentUniforms& uniforms);

#if AZAHAR_HAS_METALFX
    /// One screen draw that is run through the MetalFX spatial scaler.
    struct UpscaleJob {
        u32 screen_id{};
        Layout::DisplayOrientation orientation{};
        Common::Rectangle<f32> texcoords{};
        u32 in_width{};
        u32 in_height{};
        u32 out_width{};
        u32 out_height{};
        bool eligible{};
        bool ready{};
    };
    struct UpscaleSlot {
        id<MTLFXSpatialScaler> scaler = nil;
        id<MTLTexture> input = nil;
        id<MTLTexture> output = nil;
        u32 in_width{}, in_height{}, out_width{}, out_height{};
        bool failed{};
        bool has_output{}; ///< `output` holds the scaled result of a game frame
    };
    enum class UpscalePass { Off, Collect, Draw };

    bool UpscalingActive();
    void PrepareUpscaling(const Layout::FramebufferLayout& layout);
    bool EnsureUpscaleSlot(UpscaleSlot& slot, const UpscaleJob& job);
    void DrawUpscaled(id<MTLRenderCommandEncoder> encoder, const UpscaleJob& job, float x,
                      float y, float w, float h);
    UpscaleJob MakeUpscaleJob(u32 screen_id, float w, float h,
                              Layout::DisplayOrientation orientation) const;
#endif

private:
    Pica::PicaCore& pica;
    Instance instance;
    Scheduler scheduler;
    RasterizerMetal rasterizer;

    CAMetalLayer* layer = nil;
    bool layer_dirty{};
    CAMetalLayer* second_layer = nil; ///< Layer of the secondary window (an external display)
    bool second_layer_dirty{true};

    id<MTLRenderPipelineState> present_pipeline = nil;
    /// A post-processing shader the user wrote (see SetCustomPostShader), or nil.
    id<MTLRenderPipelineState> custom_post_pipeline = nil;
    id<MTLRenderPipelineState> present_anaglyph_pipeline = nil;
    id<MTLRenderPipelineState> present_interlaced_pipeline = nil;
    std::array<id<MTLSamplerState>, 2> present_samplers{};

    std::array<ScreenInfo, 3> screen_infos{};
    std::array<std::array<f32, 4>, 3> fill_colors{};
    std::array<bool, 3> use_fill{};
    std::array<f32, 4> o_resolution{};
    u64 previous_frame_tick{};
    u32 held_frames{};

    // Frame generation (see FrameGeneratorHooks). A frame of the game is drawn at full size into
    // a color picture, which is what is shown as the real frame. A smaller copy of the screens'
    // area goes into one of four slots; the interpolation makes the frame between the copies of
    // the previous frame and this one, which is scaled back up and shown before the real frame.
    static constexpr u32 FG_SLOTS = 4;
    // Three: the presentation queue may still read one while the game draws the next.
    static constexpr u32 FG_COLORS = 3;
    bool fg_ready{};
    bool fg_failed{};
    u32 fg_layout_width{}, fg_layout_height{}; ///< Screen size the pictures were made for
    u32 fg_slot_width{}, fg_slot_height{};     ///< Size of the slots (the smaller copies)
    /// The area of the color picture that is copied into a slot and where the made frame is drawn
    /// back, in pixels of the screen: the screens, not the empty space around them.
    f32 fg_area_x{}, fg_area_y{}, fg_area_width{}, fg_area_height{};
    Common::Rectangle<u32> fg_screens{}; ///< The screens' area the slots were made for
    bool fg_fast{};                      ///< frame_generation_fast the slots were made with
    u32 fg_cur{};
    int fg_prev{-1};
    /// A frame is being made: its callbacks show it and the real frame after it.
    std::atomic<bool> fg_busy{false};
    /// Made frames that failed in a row: when the interpolation rejects every frame, stop.
    std::atomic<u32> fg_failures{0};
    /// When the last real frame is set to reach the screen (CACurrentMediaTime), which spaces the
    /// frames after it evenly. Used by the callbacks that show the frames.
    std::shared_ptr<FrameTimeline> fg_timeline = std::make_shared<FrameTimeline>();
    u32 fg_swaps{};      ///< SwapBuffers calls (60 per second of emulation)
    u32 fg_last_swaps{}; ///< fg_swaps at the previous new frame
    f32 fg_cadence{1.0f}; ///< Swaps per new frame of the game, smoothed: 2 for a 30 FPS game
    std::chrono::steady_clock::time_point fg_last_frame{};
    double fg_interval{};
    /// The pictures of the frames in color at full size, shown as the real frames.
    std::array<id<MTLTexture>, FG_COLORS> fg_color{};
    u32 fg_color_index{};
#if AZAHAR_HAS_METALFX
    /// Scales the made frame back up to the size of its area on the screen.
    UpscaleSlot fg_upscale{};
#endif
    id<MTLComputePipelineState> fg_to_ycbcr = nil;   ///< Color picture to the slot's planes
    id<MTLRenderPipelineState> fg_from_ycbcr = nil;  ///< Slot planes onto the screen
    id<MTLSamplerState> fg_sampler = nil;
    id<MTLCommandQueue> fg_queue = nil; ///< Shows the frames of frame generation

#if AZAHAR_HAS_METALFX
    std::vector<UpscaleJob> upscale_jobs;
    std::vector<UpscaleSlot> upscale_slots;
    UpscalePass upscale_pass{UpscalePass::Off};
    std::size_t upscale_cursor{};
    int metalfx_support{-1}; // -1 unknown, 0 no, 1 yes
#endif
};

void RendererMetal::CompilePresentPipelines() {
    id<MTLDevice> device = instance.GetDevice();
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:ToNSString(Shaders::PRESENT)
                                                  options:[MTLCompileOptions new]
                                                    error:&error];
    ASSERT_MSG(library, "Failed to compile Metal present shaders: {}",
               error ? [error.localizedDescription UTF8String] : "unknown error");

    const auto make_pipeline = [&](MTLPixelFormat format, NSString* fragment = @"present_fs") {
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"present_vs"];
        desc.fragmentFunction = [library newFunctionWithName:fragment];
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

    // A shader the user wrote: their post_effect function inside a fragment function of ours.
    std::string custom_path;
    {
        std::scoped_lock lock{g_custom_post_mutex};
        custom_path = g_custom_post_path;
    }
    if (!custom_path.empty()) {
        std::string user_source;
        if (FileUtil::ReadFileToString(true, custom_path, user_source) > 0) {
            std::string source{Shaders::PRESENT};
            source += "\n// ---- user shader ----\n";
            source += user_source;
            source += "\n// ---- end of user shader ----\n";
            source += Shaders::PRESENT_POST_WRAPPER;
            NSError* custom_error = nil;
            id<MTLLibrary> custom_library =
                [device newLibraryWithSource:ToNSString(source)
                                     options:[MTLCompileOptions new]
                                       error:&custom_error];
            if (custom_library == nil) {
                LOG_ERROR(Render, "The post-processing shader {} does not compile: {}", custom_path,
                          custom_error ? [custom_error.localizedDescription UTF8String]
                                       : "unknown error");
            } else {
                MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
                desc.vertexFunction = [custom_library newFunctionWithName:@"present_vs"];
                desc.fragmentFunction = [custom_library newFunctionWithName:@"present_post_fs"];
                MTLRenderPipelineColorAttachmentDescriptor* color = desc.colorAttachments[0];
                color.pixelFormat = MTLPixelFormatBGRA8Unorm;
                color.blendingEnabled = YES;
                color.rgbBlendOperation = MTLBlendOperationAdd;
                color.alphaBlendOperation = MTLBlendOperationAdd;
                color.sourceRGBBlendFactor = MTLBlendFactorBlendAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusBlendAlpha;
                color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                color.destinationAlphaBlendFactor = MTLBlendFactorZero;
                NSError* pipeline_error = nil;
                custom_post_pipeline =
                    [device newRenderPipelineStateWithDescriptor:desc error:&pipeline_error];
                if (custom_post_pipeline == nil) {
                    LOG_ERROR(Render, "The post-processing shader {} cannot be used: {}",
                              custom_path,
                              pipeline_error ? [pipeline_error.localizedDescription UTF8String]
                                             : "unknown error");
                } else {
                    LOG_INFO(Render, "Post-processing shader: {}", custom_path);
                }
            }
        } else {
            LOG_ERROR(Render, "The post-processing shader {} cannot be read", custom_path);
        }
    }
    present_anaglyph_pipeline = make_pipeline(MTLPixelFormatBGRA8Unorm, @"present_anaglyph_fs");
    present_interlaced_pipeline = make_pipeline(MTLPixelFormatBGRA8Unorm, @"present_interlaced_fs");

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

CAMetalLayer* RendererMetal::ConfigureLayer(void* surface) {
    if (!surface) {
        return nil;
    }
    CAMetalLayer* result = (__bridge CAMetalLayer*)surface;
    result.device = instance.GetDevice();
    result.pixelFormat = MTLPixelFormatBGRA8Unorm;
    result.framebufferOnly = YES;
    result.maximumDrawableCount = 3;
    return result;
}

void RendererMetal::AcquireLayer() {
    layer_dirty = false;
    layer = ConfigureLayer(render_window.GetWindowInfo().render_surface);
    if (layer == nil) {
        LOG_WARNING(Render, "No render surface provided, the Metal renderer runs headless");
    }
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

void RendererMetal::DrawQuad(id<MTLRenderCommandEncoder> encoder,
                             const std::array<ScreenRectVertex, 4>& vertices,
                             id<MTLTexture> texture, const PresentUniforms& uniforms) {
    [encoder setVertexBytes:vertices.data()
                     length:sizeof(ScreenRectVertex) * vertices.size()
                    atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    if (texture != nil) {
        [encoder setFragmentTexture:texture atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

void RendererMetal::DrawSingleScreen(id<MTLRenderCommandEncoder> encoder, u32 screen_id, float x,
                                     float y, float w, float h,
                                     Layout::DisplayOrientation orientation) {
    const ScreenInfo& screen_info = screen_infos[screen_id];
    if (!use_fill[screen_id] && screen_info.texture == nil) {
        return;
    }

#if AZAHAR_HAS_METALFX
    if (upscale_pass == UpscalePass::Collect) {
        // Only records what would be drawn, the scaler runs before the actual draw.
        upscale_jobs.push_back(MakeUpscaleJob(screen_id, w, h, orientation));
        return;
    }
    if (upscale_pass == UpscalePass::Draw) {
        if (upscale_cursor < upscale_jobs.size()) {
            const UpscaleJob& job = upscale_jobs[upscale_cursor++];
            if (job.ready) {
                DrawUpscaled(encoder, job, x, y, w, h);
                return;
            }
        }
    }
#endif

    std::array<ScreenRectVertex, 4> vertices;
    if (!MakeScreenVertices(vertices, screen_info.texcoords, x, y, w, h, orientation)) {
        LOG_ERROR(Render, "Unknown DisplayOrientation: {}", orientation);
        return;
    }
    const PresentUniforms uniforms = {
        .o_resolution = o_resolution,
        .fill_color = fill_colors[screen_id],
        .use_fill = use_fill[screen_id] ? 1 : 0,
        .effect = g_post_effect.load(std::memory_order_relaxed),
    };
    DrawQuad(encoder, vertices, screen_info.texture, uniforms);
}

void RendererMetal::DrawSingleScreenStereo(id<MTLRenderCommandEncoder> encoder, u32 screen_id_l,
                                           u32 screen_id_r, float x, float y, float w, float h,
                                           Layout::DisplayOrientation orientation) {
    const ScreenInfo& left = screen_infos[screen_id_l];
    const ScreenInfo& right = screen_infos[screen_id_r];
    if (left.texture == nil || right.texture == nil) {
        return;
    }

    id<MTLTexture> left_texture = left.texture;
    id<MTLTexture> right_texture = right.texture;
    bool upscaled = false;
#if AZAHAR_HAS_METALFX
    // Each eye goes through the scaler on its own, the screens that show the same picture in both
    // eyes (the bottom screen) only once.
    if (upscale_pass == UpscalePass::Collect) {
        upscale_jobs.push_back(MakeUpscaleJob(screen_id_l, w, h, orientation));
        if (screen_id_r != screen_id_l) {
            upscale_jobs.push_back(MakeUpscaleJob(screen_id_r, w, h, orientation));
        }
        return;
    }
    if (upscale_pass == UpscalePass::Draw) {
        const std::size_t first = upscale_cursor;
        upscale_cursor += screen_id_r != screen_id_l ? 2 : 1;
        if (upscale_cursor <= upscale_jobs.size()) {
            const std::size_t second = screen_id_r != screen_id_l ? first + 1 : first;
            if (upscale_jobs[first].ready && upscale_jobs[second].ready) {
                left_texture = upscale_slots[first].output;
                right_texture = upscale_slots[second].output;
                upscaled = true;
            }
        }
    }
#endif

    std::array<ScreenRectVertex, 4> vertices;
    if (upscaled) {
        // The scaled screens already have the orientation they are shown in.
        vertices = {{
            ScreenRectVertex(x, y, 0.0f, 0.0f),
            ScreenRectVertex(x + w, y, 1.0f, 0.0f),
            ScreenRectVertex(x, y + h, 0.0f, 1.0f),
            ScreenRectVertex(x + w, y + h, 1.0f, 1.0f),
        }};
    } else if (!MakeScreenVertices(vertices, left.texcoords, x, y, w, h, orientation)) {
        LOG_ERROR(Render, "Unknown DisplayOrientation: {}", orientation);
        return;
    }
    // The interlacing alternates over the extent along the texture's x axis, which is the height
    // of the rectangle when it is shown rotated.
    const bool rotated = orientation == Layout::DisplayOrientation::Portrait ||
                         orientation == Layout::DisplayOrientation::PortraitFlipped;

    const auto mode = Settings::values.render_3d.GetValue();
    PresentUniforms uniforms = {
        .o_resolution = o_resolution,
        .fill_color = {},
        .use_fill = 0,
        .reverse_interlaced = mode == Settings::StereoRenderOption::ReverseInterlaced ? 1 : 0,
        // Scaled screens have their rows along the y axis of the texture, native ones along x.
        .interlace_rows = (rotated && !upscaled) ? w : h,
        .interlace_use_y = upscaled ? 1 : 0,
        .effect = 0,
        .anaglyph_mode = g_anaglyph_mode.load(std::memory_order_relaxed),
    };
    [encoder setRenderPipelineState:mode == Settings::StereoRenderOption::Anaglyph
                                        ? present_anaglyph_pipeline
                                        : present_interlaced_pipeline];
    [encoder setFragmentTexture:left_texture atIndex:0];
    [encoder setFragmentTexture:right_texture atIndex:1];
    [encoder setVertexBytes:vertices.data()
                     length:sizeof(ScreenRectVertex) * vertices.size()
                    atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    // The other screens use the plain pipeline again.
    [encoder setRenderPipelineState:custom_post_pipeline != nil ? custom_post_pipeline
                                                                : present_pipeline];
}

#if AZAHAR_HAS_METALFX

RendererMetal::UpscaleJob RendererMetal::MakeUpscaleJob(
    u32 screen_id, float w, float h, Layout::DisplayOrientation orientation) const {
    const ScreenInfo& screen_info = screen_infos[screen_id];
    UpscaleJob job;
    job.screen_id = screen_id;
    job.orientation = orientation;
    job.texcoords = screen_info.texcoords;
    id<MTLTexture> texture = screen_info.texture;
    if (!use_fill[screen_id] && texture != nil && w >= 1.0f && h >= 1.0f) {
        const bool swap = orientation == Layout::DisplayOrientation::Landscape ||
                          orientation == Layout::DisplayOrientation::LandscapeFlipped;
        const auto& tc = job.texcoords;
        const float source_width = std::abs(tc.bottom - tc.top) * static_cast<float>(texture.width);
        const float source_height =
            std::abs(tc.right - tc.left) * static_cast<float>(texture.height);
        // Size of the screen at the resolution the game renders it in, in the orientation it is
        // shown in.
        job.in_width = static_cast<u32>(std::lround(swap ? source_height : source_width));
        job.in_height = static_cast<u32>(std::lround(swap ? source_width : source_height));
        job.out_width = static_cast<u32>(std::lround(w));
        job.out_height = static_cast<u32>(std::lround(h));
        // Only worth it when the screen is shown clearly larger than it is drawn: the scaler costs
        // several milliseconds of GPU time, and for a small enlargement (such as the bottom screen
        // at 3x) plain bilinear filtering looks the same.
        job.eligible = job.in_width >= 16 && job.in_height >= 16 &&
                       job.out_width * 4 >= job.in_width * 5 &&
                       job.out_height * 4 >= job.in_height * 5;
    }
    return job;
}

bool RendererMetal::UpscalingActive() {
    if (g_upscaler_mode.load(std::memory_order_relaxed) != static_cast<int>(UpscalerMode::Spatial)) {
        return false;
    }
    if (metalfx_support < 0) {
        metalfx_support = MetalFXSupported(instance.GetDevice()) ? 1 : 0;
        LOG_INFO(Render, "MetalFX spatial upscaling is {}",
                 metalfx_support ? "available" : "not available on this device");
    }
    return metalfx_support == 1;
}

bool RendererMetal::EnsureUpscaleSlot(UpscaleSlot& slot, const UpscaleJob& job) {
    if (slot.in_width == job.in_width && slot.in_height == job.in_height &&
        slot.out_width == job.out_width && slot.out_height == job.out_height) {
        return !slot.failed;
    }
    slot = UpscaleSlot{};
    slot.in_width = job.in_width;
    slot.in_height = job.in_height;
    slot.out_width = job.out_width;
    slot.out_height = job.out_height;
    slot.failed = true;

    if (@available(iOS 16.0, macOS 13.0, *)) {
        id<MTLDevice> device = instance.GetDevice();
        MTLFXSpatialScalerDescriptor* desc = [MTLFXSpatialScalerDescriptor new];
        desc.inputWidth = job.in_width;
        desc.inputHeight = job.in_height;
        desc.outputWidth = job.out_width;
        desc.outputHeight = job.out_height;
        desc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:device];
        if (scaler == nil) {
            LOG_WARNING(Render, "MetalFX refused to scale {}x{} to {}x{}, drawing it unscaled",
                        job.in_width, job.in_height, job.out_width, job.out_height);
            return false;
        }

        MTLTextureDescriptor* in_desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:job.in_width
                                                              height:job.in_height
                                                           mipmapped:NO];
        in_desc.usage = MTLTextureUsageRenderTarget | scaler.colorTextureUsage;
        in_desc.storageMode = MTLStorageModePrivate;
        MTLTextureDescriptor* out_desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:job.out_width
                                                              height:job.out_height
                                                           mipmapped:NO];
        out_desc.usage = MTLTextureUsageShaderRead | scaler.outputTextureUsage;
        out_desc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> input = [device newTextureWithDescriptor:in_desc];
        id<MTLTexture> output = [device newTextureWithDescriptor:out_desc];
        if (input == nil || output == nil) {
            LOG_WARNING(Render, "Unable to allocate the MetalFX textures");
            return false;
        }
        SetLabel(input, "MetalFX input");
        SetLabel(output, "MetalFX output");
        slot.scaler = scaler;
        slot.input = input;
        slot.output = output;
        slot.failed = false;
        LOG_INFO(Render, "MetalFX spatial scaler: {}x{} -> {}x{}", job.in_width, job.in_height,
                 job.out_width, job.out_height);
        return true;
    }
    return false;
}

void RendererMetal::PrepareUpscaling(const Layout::FramebufferLayout& layout) {
    upscale_jobs.clear();
    upscale_cursor = 0;
    upscale_pass = UpscalePass::Off;
    if (!UpscalingActive()) {
        return;
    }

    // Find out which screens are drawn and how big, without drawing anything.
    upscale_pass = UpscalePass::Collect;
    DrawScreens(nil, layout);

    if (upscale_slots.size() < upscale_jobs.size()) {
        upscale_slots.resize(upscale_jobs.size());
    }
    bool any = false;
    for (std::size_t i = 0; i < upscale_jobs.size(); i++) {
        UpscaleJob& job = upscale_jobs[i];
        if (!job.eligible || !EnsureUpscaleSlot(upscale_slots[i], job)) {
            continue;
        }
        UpscaleSlot& slot = upscale_slots[i];

        // The game did not present a new frame since the output was made (a 30 fps game shown at
        // 60 Hz), so scaling the same picture again would only burn GPU time.
        if (slot.has_output && !Core::PerfStats::game_frames_updated) {
            job.ready = true;
            any = true;
            continue;
        }

        // Draw the screen at the resolution it is rendered in, in the orientation it is shown in.
        // This also crops the part of the texture that is displayed and converts its format.
        MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
        desc.colorAttachments[0].texture = slot.input;
        desc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
        const float width = static_cast<float>(job.in_width);
        const float height = static_cast<float>(job.in_height);
        std::array<ScreenRectVertex, 4> vertices;
        if (!MakeScreenVertices(vertices, job.texcoords, 0.0f, 0.0f, width, height,
                                job.orientation)) {
            scheduler.EndEncoding();
            continue;
        }
        [encoder setRenderPipelineState:present_pipeline];
        [encoder setFragmentSamplerState:present_samplers[1] atIndex:0];
        [encoder setViewport:MTLViewport{0.0, 0.0, width, height, 0.0, 1.0}];
        SetOpacity(encoder, 1.0f);
        const PresentUniforms uniforms = {
            .o_resolution = {width, height, 1.0f / width, 1.0f / height},
            .fill_color = {},
            .use_fill = 0,
        };
        DrawQuad(encoder, vertices, screen_infos[job.screen_id].texture, uniforms);
        scheduler.EndEncoding();

        if (@available(iOS 16.0, macOS 13.0, *)) {
            slot.scaler.colorTexture = slot.input;
            slot.scaler.outputTexture = slot.output;
            slot.scaler.inputContentWidth = job.in_width;
            slot.scaler.inputContentHeight = job.in_height;
            [slot.scaler encodeToCommandBuffer:scheduler.CommandBuffer()];
            slot.has_output = true;
            job.ready = true;
            any = true;
        }
    }
    upscale_pass = any ? UpscalePass::Draw : UpscalePass::Off;
    upscale_cursor = 0;
}

void RendererMetal::DrawUpscaled(id<MTLRenderCommandEncoder> encoder, const UpscaleJob& job,
                                 float x, float y, float w, float h) {
    // The scaler output already has the right orientation and covers the whole rectangle.
    const std::array<ScreenRectVertex, 4> vertices{{
        ScreenRectVertex(x, y, 0.0f, 0.0f),
        ScreenRectVertex(x + w, y, 1.0f, 0.0f),
        ScreenRectVertex(x, y + h, 0.0f, 1.0f),
        ScreenRectVertex(x + w, y + h, 1.0f, 1.0f),
    }};
    // Find the slot of this job: jobs and slots share their index.
    const std::size_t index = static_cast<std::size_t>(&job - upscale_jobs.data());
    const PresentUniforms uniforms = {
        .o_resolution = o_resolution,
        .fill_color = {},
        .use_fill = 0,
        .effect = g_post_effect.load(std::memory_order_relaxed),
    };
    DrawQuad(encoder, vertices, upscale_slots[index].output, uniforms);
}

#endif // AZAHAR_HAS_METALFX

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
    case Settings::StereoRenderOption::Anaglyph:
    case Settings::StereoRenderOption::Interlaced:
    case Settings::StereoRenderOption::ReverseInterlaced:
        DrawSingleScreenStereo(encoder, leftside, rightside, left, top, width, height,
                               orientation);
        break;
    case Settings::StereoRenderOption::Off:
    default: {
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
    case Settings::StereoRenderOption::Anaglyph:
    case Settings::StereoRenderOption::Interlaced:
    case Settings::StereoRenderOption::ReverseInterlaced:
        DrawSingleScreenStereo(encoder, 2, 2, left, top, width, height, orientation);
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

    [encoder setRenderPipelineState:custom_post_pipeline != nil ? custom_post_pipeline
                                                                : present_pipeline];
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

void RendererMetal::RenderToLayer(CAMetalLayer* target, const Layout::FramebufferLayout& layout,
                                  bool allow_upscale) {
    if (target == nil || layout.width == 0 || layout.height == 0) {
        return;
    }

    const CGSize size = CGSizeMake(layout.width, layout.height);
    if (!CGSizeEqualToSize(target.drawableSize, size)) {
        target.drawableSize = size;
    }

    if (allow_upscale && UseFrameGeneration(layout)) {
        // Takes its drawables itself, when the frames are ready to be shown.
        RenderGenerated(target, layout);
        return;
    }

    id<CAMetalDrawable> drawable = nil;
    const auto drawable_start = std::chrono::steady_clock::now();
    @autoreleasepool {
        drawable = [target nextDrawable];
    }
    Stats().drawable_ns.fetch_add(static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                       std::chrono::steady_clock::now() - drawable_start)
                                                       .count()),
                                  std::memory_order_relaxed);
    if (drawable == nil) {
        return;
    }

    // Submit the rendering of the game so the presentation (upscaling and drawing the screens)
    // gets a command buffer of its own, whose GPU time is reported separately.
    scheduler.Flush();
    scheduler.MarkPresentation();
#if AZAHAR_HAS_METALFX
    // MetalFX keeps its textures per screen, only the main layer uses it.
    if (allow_upscale) {
        PrepareUpscaling(layout);
    }
#endif

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
    // The second display is not paced or measured, it only follows the first.
    scheduler.PresentDrawable(drawable, allow_upscale);
#if AZAHAR_HAS_METALFX
    upscale_pass = UpscalePass::Off;
#endif
}

bool RendererMetal::UseFrameGeneration(const Layout::FramebufferLayout& layout) {
    const int mode = GetQualityOptions().frame_generation;
    if (mode <= 0 || !g_fg_hooks.prepare || !g_fg_hooks.texture || !g_fg_hooks.interpolate) {
        fg_prev = -1;
        return false;
    }
    // The area of the screen the game is shown in. Interpolation costs the same for every pixel,
    // so the empty space around the screens is left out.
    Common::Rectangle<u32> screens{0, 0, layout.width, layout.height};
    {
        bool any = false;
        Common::Rectangle<u32> box{};
        const auto add = [&](const Common::Rectangle<u32>& r) {
            if (r.GetWidth() == 0 || r.GetHeight() == 0) {
                return;
            }
            if (!any) {
                box = r;
                any = true;
            } else {
                box.left = std::min(box.left, r.left);
                box.top = std::min(box.top, r.top);
                box.right = std::max(box.right, r.right);
                box.bottom = std::max(box.bottom, r.bottom);
            }
        };
        // Only the top screen when asked (and shown): the bottom one then keeps the game's frames.
        const bool top_only =
            GetQualityOptions().frame_generation_top_only && layout.top_screen_enabled;
        if (layout.top_screen_enabled) {
            add(layout.top_screen);
        }
        if (layout.bottom_screen_enabled && !top_only) {
            add(layout.bottom_screen);
        }
        if (any) {
            screens.left = std::min(box.left, layout.width);
            screens.top = std::min(box.top, layout.height);
            screens.right = std::clamp(box.right, screens.left, layout.width);
            screens.bottom = std::clamp(box.bottom, screens.top, layout.height);
        }
    }

    const bool fast = GetQualityOptions().frame_generation_fast;
    if (layout.width != fg_layout_width || layout.height != fg_layout_height ||
        screens.left != fg_screens.left || screens.top != fg_screens.top ||
        screens.right != fg_screens.right || screens.bottom != fg_screens.bottom ||
        fast != fg_fast) {
        fg_fast = fast;
        fg_layout_width = layout.width;
        fg_layout_height = layout.height;
        fg_screens = screens;
        fg_prev = -1;
        fg_ready = false;
        fg_failures.store(0, std::memory_order_relaxed);
        // The interpolation works on a copy at half the size: about a quarter of the work, and
        // the made frame is scaled back up. Smaller when the interpolation refuses that size.
        const auto round_up = [](u32 value) { return (value + 15u) & ~15u; };
        // The faster setting starts at 3/8 of the size: about 44% fewer pixels than half.
        const std::array<f32, 3> scales = fast ? std::array<f32, 3>{0.375f, 0.25f, 0.0f}
                                               : std::array<f32, 3>{0.5f, 0.375f, 0.25f};
        for (const f32 scale : scales) {
            if (scale <= 0.0f) {
                break;
            }
            // The whole screen at this scale, in multiples of 16 (video processors work in
            // blocks), rounded down so the area never reaches outside the screen.
            const u32 width = static_cast<u32>(std::floor(layout.width * scale)) & ~15u;
            const u32 height = static_cast<u32>(std::floor(layout.height * scale)) & ~15u;
            if (width < 64 || height < 64) {
                break;
            }
            const f32 sx = static_cast<f32>(width) / static_cast<f32>(layout.width);
            const f32 sy = static_cast<f32>(height) / static_cast<f32>(layout.height);
            const u32 slot_width = std::clamp(
                round_up(static_cast<u32>(std::ceil(screens.GetWidth() * sx))), 64u, width);
            const u32 slot_height = std::clamp(
                round_up(static_cast<u32>(std::ceil(screens.GetHeight() * sy))), 64u, height);
            if (g_fg_hooks.prepare((__bridge void*)instance.GetDevice(), slot_width,
                                   slot_height)) {
                fg_slot_width = slot_width;
                fg_slot_height = slot_height;
                // The slot covers a little more than the screens (the rounding up).
                fg_area_width = static_cast<f32>(slot_width) / sx;
                fg_area_height = static_cast<f32>(slot_height) / sy;
                fg_area_x = std::clamp(static_cast<f32>(screens.left), 0.0f,
                                       std::max(0.0f, layout.width - fg_area_width));
                fg_area_y = std::clamp(static_cast<f32>(screens.top), 0.0f,
                                       std::max(0.0f, layout.height - fg_area_height));
                fg_ready = PrepareFrameGenerationResources();
                if (!fg_ready) {
                    break;
                }
                const char* scaling = ", stretched with plain filtering";
#if AZAHAR_HAS_METALFX
                if (fg_upscale.scaler != nil) {
                    scaling = ", scaled up with MetalFX";
                }
#endif
                LOG_INFO(Render,
                         "Frame generation ready: {}x{} frames for an area of {:.0f}x{:.0f} of a "
                         "{}x{} screen{}",
                         slot_width, slot_height, fg_area_width, fg_area_height, layout.width,
                         layout.height, scaling);
                break;
            }
            LOG_INFO(Render, "Frame generation is not available for {}x{} frames", slot_width,
                     slot_height);
        }
        fg_failed = !fg_ready;
        if (!fg_ready) {
            LOG_WARNING(Render, "Frame generation is not available for this screen size");
        }
    }
    if (fg_ready && fg_failures.load(std::memory_order_relaxed) >= 120) {
        LOG_WARNING(Render, "Frame generation stopped: the interpolation rejected 120 frames in a "
                            "row");
        fg_ready = false;
        fg_failed = true;
        fg_prev = -1;
    }
    if (!fg_ready) {
        return false;
    }

    // The time between the game's frames, smoothed, which spaces the made frame. A pause or a
    // menu does not count.
    const auto now = std::chrono::steady_clock::now();
    if (fg_last_frame.time_since_epoch().count() != 0) {
        const double elapsed = std::chrono::duration<double>(now - fg_last_frame).count();
        if (elapsed > 0.1) {
            fg_prev = -1;
            fg_interval = 0.0;
        } else {
            fg_interval = fg_interval == 0.0 ? elapsed : fg_interval * 0.7 + elapsed * 0.3;
        }
    }
    fg_last_frame = now;

    // Whether the game draws at 30 FPS is counted in emulated time (how many 60 Hz refreshes go
    // by per new frame), not in real time: a game slowed down by anything must not look like a
    // 30 FPS game, or frame generation would keep it slow.
    const u32 swaps = fg_swaps - fg_last_swaps;
    fg_last_swaps = fg_swaps;
    fg_cadence = fg_cadence * 0.8f + static_cast<f32>(std::min(swaps, 4u)) * 0.2f;
    const bool thirty_fps = fg_cadence >= 1.7f;
    // Only games that draw at 30 FPS: making a frame takes over 10 ms on an A18 Pro, which does
    // not fit between the frames of a 60 FPS game. Not while fast forwarding either, where the
    // frames come as fast as those of a 60 FPS game or faster.
    const double limit = Settings::GetFrameLimit();
    const bool eligible = fg_interval > 0.0 && thirty_fps && limit > 0.0 && limit <= 110.0;
    if (!eligible) {
        // The frame is drawn the usual way and the next one starts over.
        fg_prev = -1;
        return false;
    }
    return true;
}

namespace {
/// Converts the picture of a frame into the 4:2:0 YCbCr planes the interpolation takes (BT.709,
/// video range), and draws such planes back onto the screen.
constexpr const char* kFrameGenerationShaders = R"(
#include <metal_stdlib>
using namespace metal;

// The area of the color picture that is copied, in its pixels.
struct ConvertArea {
    float2 origin;
    float2 size;
};

// Copies the area into the planes, which are smaller: every pixel of the planes is a filtered
// sample of the picture.
kernel void to_ycbcr(texture2d<float> color [[texture(0)]],
                     texture2d<float, access::write> luma [[texture(1)]],
                     texture2d<float, access::write> chroma [[texture(2)]],
                     constant ConvertArea& area [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) {
        return;
    }
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    const float2 luma_size = float2(luma.get_width(), luma.get_height());
    const float2 color_size = float2(color.get_width(), color.get_height());
    float2 cbcr = float2(0.0);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 p = gid * 2 + uint2(dx, dy);
            const float2 uv =
                (area.origin + (float2(p) + 0.5) / luma_size * area.size) / color_size;
            const float3 c = color.sample(smp, uv, level(0.0)).rgb;
            const float y = dot(c, float3(0.2126, 0.7152, 0.0722));
            luma.write(float4((16.0 + 219.0 * y) / 255.0), p);
            cbcr += float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
        }
    }
    cbcr *= 0.25;
    chroma.write(float4((128.0 + 224.0 * cbcr) / 255.0, 0.0, 0.0), gid);
}

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 uv = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 from_ycbcr(FullscreenOut in [[stage_in]],
                           texture2d<float> luma [[texture(0)]],
                           texture2d<float> chroma [[texture(1)]],
                           sampler s [[sampler(0)]]) {
    const float y = (luma.sample(s, in.uv).r * 255.0 - 16.0) / 219.0;
    const float2 c = (chroma.sample(s, in.uv).rg * 255.0 - 128.0) / 224.0;
    const float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y,
                              y + 1.8556 * c.x);
    return float4(saturate(rgb), 1.0);
}
)";
} // Anonymous namespace

bool RendererMetal::PrepareFrameGenerationResources() {
    id<MTLDevice> device = instance.GetDevice();
    if (fg_queue == nil) {
        fg_queue = [device newCommandQueue];
        if (fg_queue == nil) {
            return false;
        }
    }
    if (fg_to_ycbcr == nil || fg_from_ycbcr == nil) {
        NSError* error = nil;
        id<MTLLibrary> library =
            [device newLibraryWithSource:[NSString stringWithUTF8String:kFrameGenerationShaders]
                                 options:nil
                                   error:&error];
        if (library == nil) {
            LOG_ERROR(Render, "Frame generation shaders failed to compile: {}",
                      error ? error.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        fg_to_ycbcr = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"to_ycbcr"]
                                                            error:&error];
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"fullscreen_vertex"];
        desc.fragmentFunction = [library newFunctionWithName:@"from_ycbcr"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        fg_from_ycbcr = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (fg_to_ycbcr == nil || fg_from_ycbcr == nil) {
            LOG_ERROR(Render, "Frame generation pipelines failed: {}",
                      error ? error.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        MTLSamplerDescriptor* sampler = [MTLSamplerDescriptor new];
        sampler.minFilter = MTLSamplerMinMagFilterLinear;
        sampler.magFilter = MTLSamplerMinMagFilterLinear;
        sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
        fg_sampler = [device newSamplerStateWithDescriptor:sampler];
    }

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:fg_layout_width
                                                          height:fg_layout_height
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    for (u32 i = 0; i < FG_COLORS; i++) {
        fg_color[i] = [device newTextureWithDescriptor:desc];
        if (fg_color[i] == nil) {
            return false;
        }
    }

#if AZAHAR_HAS_METALFX
    // The made frame is scaled up to its area on the screen with MetalFX, like the real picture
    // can be. Without it (not supported, or refused) it is stretched with plain filtering.
    fg_upscale = UpscaleSlot{};
    if (MetalFXSupported(device)) {
        UpscaleJob job;
        job.in_width = fg_slot_width;
        job.in_height = fg_slot_height;
        job.out_width = static_cast<u32>(std::lround(fg_area_width));
        job.out_height = static_cast<u32>(std::lround(fg_area_height));
        if (!EnsureUpscaleSlot(fg_upscale, job)) {
            fg_upscale = UpscaleSlot{};
        }
    }
#endif
    return true;
}

void RendererMetal::RenderGenerated(CAMetalLayer* target,
                                    const Layout::FramebufferLayout& layout) {
    // The frames go to the screen from the callbacks of the interpolation, in order. While the
    // previous ones are still on their way, this frame is dropped: the emulation never waits for
    // frame generation, and a frame shown out of order would be worse than one not shown.
    if (fg_busy.load(std::memory_order_acquire)) {
        Stats().fg_skipped.fetch_add(1, std::memory_order_relaxed);
        fg_prev = -1;
        return;
    }
    const double arrived = CACurrentMediaTime();

    fg_color_index = (fg_color_index + 1) % FG_COLORS;
    id<MTLTexture> current = fg_color[fg_color_index];
    id<MTLTexture> current_luma = (__bridge id<MTLTexture>)g_fg_hooks.texture(fg_cur, 0);
    id<MTLTexture> current_chroma = (__bridge id<MTLTexture>)g_fg_hooks.texture(fg_cur, 1);
    if (current == nil || current_luma == nil || current_chroma == nil) {
        fg_ready = false;
        return;
    }

    // The frame of the game at full size, drawn exactly as it is without frame generation.
    scheduler.Flush();
    scheduler.MarkPresentation();
#if AZAHAR_HAS_METALFX
    PrepareUpscaling(layout);
#endif
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = current;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor =
        MTLClearColorMake(Settings::values.bg_red.GetValue(), Settings::values.bg_green.GetValue(),
                          Settings::values.bg_blue.GetValue(), 1.0);
    id<MTLRenderCommandEncoder> encoder = scheduler.BeginRendering(desc);
    DrawScreens(encoder, layout);
    scheduler.EndEncoding();
#if AZAHAR_HAS_METALFX
    upscale_pass = UpscalePass::Off;
#endif

    const u32 previous = fg_prev >= 0 ? static_cast<u32>(fg_prev) : 0;
    const bool make_between = fg_prev >= 0;
    const u32 source = fg_cur;
    const u32 destination = (fg_cur + 2) % FG_SLOTS;
    id<MTLTexture> between_luma = (__bridge id<MTLTexture>)g_fg_hooks.texture(destination, 0);
    id<MTLTexture> between_chroma = (__bridge id<MTLTexture>)g_fg_hooks.texture(destination, 1);

    // The smaller copy of the screens' area, in the planes the interpolation reads.
    {
        id<MTLComputeCommandEncoder> convert = [scheduler.CommandBuffer() computeCommandEncoder];
        [convert setComputePipelineState:fg_to_ycbcr];
        [convert setTexture:current atIndex:0];
        [convert setTexture:current_luma atIndex:1];
        [convert setTexture:current_chroma atIndex:2];
        const std::array<f32, 4> area{fg_area_x, fg_area_y, fg_area_width, fg_area_height};
        [convert setBytes:area.data() length:sizeof(area) atIndex:0];
        const MTLSize group = MTLSizeMake(8, 8, 1);
        const MTLSize groups =
            MTLSizeMake((fg_slot_width / 2 + 7) / 8, (fg_slot_height / 2 + 7) / 8, 1);
        [convert dispatchThreadgroups:groups threadsPerThreadgroup:group];
        [convert endEncoding];
    }

    const f32 width = static_cast<f32>(layout.width);
    const f32 height = static_cast<f32>(layout.height);
    const f32 area_x = fg_area_x, area_y = fg_area_y;
    const f32 area_width = fg_area_width, area_height = fg_area_height;

    // The time between two frames of the game, which the frames on screen are spaced by: the
    // exact time of the emulated frames when the game holds its speed, the measured one otherwise.
    const double nominal = std::round(fg_cadence) / 59.83 * 100.0 / Settings::GetFrameLimit();
    const double interval =
        std::clamp(std::abs(fg_interval - nominal) < nominal * 0.05 ? nominal : fg_interval, 0.02,
                   0.1);

    fg_busy.store(true, std::memory_order_release);
    std::atomic<bool>* busy = &fg_busy;
    std::atomic<u32>* failures = &fg_failures;
    const std::shared_ptr<FrameTimeline> timeline = fg_timeline;
    // Half the time between two frames of the game, in refreshes of a 60 Hz display (one for a
    // 30 FPS game at full speed), and the step of the display's refreshes.
    const double tick60 = 1.0 / 60.0;
    const double half = std::max(1.0, std::round(interval * 0.5 * 60.0)) * tick60;
    // A queue of its own: on the emulation's queue the frames would wait behind the drawing of
    // the game's next frame and miss their refresh.
    id<MTLCommandQueue> queue = fg_queue;
    id<MTLRenderPipelineState> color_pipeline = present_pipeline;
    id<MTLSamplerState> color_sampler = present_samplers[0];
    id<MTLRenderPipelineState> ycbcr_pipeline = fg_from_ycbcr;
    id<MTLSamplerState> ycbcr_sampler = fg_sampler;
    const auto interpolate = g_fg_hooks.interpolate;
#if AZAHAR_HAS_METALFX
    id<MTLFXSpatialScaler> scaler = fg_upscale.scaler;
    id<MTLTexture> scaler_input = fg_upscale.input;
    id<MTLTexture> scaler_output = fg_upscale.output;
    const u32 scaler_width = fg_upscale.in_width;
    const u32 scaler_height = fg_upscale.in_height;
#endif

    // Shows the made frame (when there is one) and the real one. Runs on a callback thread, which
    // is where the waits for drawables happen, not on the emulation thread.
    const auto show = std::make_shared<std::function<void(bool)>>([=](bool made) {
        made = made && between_luma != nil && between_chroma != nil;
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        const auto begin = [&](id<MTLTexture> to) {
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = to;
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            return [buffer renderCommandEncoderWithDescriptor:pass];
        };
        // The planes of the made frame as a color picture over the whole target or viewport.
        const auto draw_planes = [&](id<MTLRenderCommandEncoder> draw, MTLViewport viewport) {
            [draw setRenderPipelineState:ycbcr_pipeline];
            [draw setViewport:viewport];
            [draw setFragmentTexture:between_luma atIndex:0];
            [draw setFragmentTexture:between_chroma atIndex:1];
            [draw setFragmentSamplerState:ycbcr_sampler atIndex:0];
            [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        };

        id<CAMetalDrawable> drawable_between = nil;
        if (made) {
            @autoreleasepool {
                drawable_between = [target nextDrawable];
            }
            made = drawable_between != nil;
        }
        if (made) {
            bool scaled = false;
#if AZAHAR_HAS_METALFX
            if (scaler != nil) {
                if (@available(iOS 16.0, macOS 13.0, *)) {
                    // The made frame in color at its own size, then scaled up by MetalFX.
                    id<MTLRenderCommandEncoder> convert = begin(scaler_input);
                    draw_planes(convert,
                                MTLViewport{0.0, 0.0, static_cast<double>(scaler_width),
                                            static_cast<double>(scaler_height), 0.0, 1.0});
                    [convert endEncoding];
                    scaler.colorTexture = scaler_input;
                    scaler.outputTexture = scaler_output;
                    scaler.inputContentWidth = scaler_width;
                    scaler.inputContentHeight = scaler_height;
                    [scaler encodeToCommandBuffer:buffer];
                    scaled = true;
                }
            }
#endif
            id<MTLRenderCommandEncoder> draw = begin(drawable_between.texture);
            // Around the screens (borders, background) the real frame, over them the made one.
            EncodeFullscreen(draw, color_pipeline, color_sampler, current, width, height);
#if AZAHAR_HAS_METALFX
            if (scaled) {
                EncodeRect(draw, color_pipeline, color_sampler, scaler_output, width, height,
                           area_x, area_y, area_width, area_height);
            }
#endif
            if (!scaled) {
                draw_planes(draw, MTLViewport{area_x, area_y, area_width, area_height, 0.0, 1.0});
            }
            [draw endEncoding];
        }

        id<CAMetalDrawable> drawable_current = nil;
        @autoreleasepool {
            drawable_current = [target nextDrawable];
        }
        if (drawable_current != nil) {
            id<MTLRenderCommandEncoder> draw = begin(drawable_current.texture);
            EncodeFullscreen(draw, color_pipeline, color_sampler, current, width, height);
            [draw endEncoding];
        }

        // When the frames reach the screen. A display shows a frame at its next refresh, so a
        // frame that is a moment late is a whole refresh late. The frames are therefore set to
        // refreshes: counted from the refresh the previous real frame was really shown at (the
        // display reports it), the made frame goes half a frame of the game later and the real
        // frame another half later. A frame that can't make its refresh takes the next one.
        const double now = CACurrentMediaTime();
        const double earliest = now + timeline->lead.load(std::memory_order_relaxed);
        // The first slot at or after `first` that this frame can still make. Slots are half a
        // frame of the game apart, which is a refresh of the display at 60 Hz and two at 120 Hz,
        // so the made and real frames keep alternating evenly when one has to wait.
        const auto refresh = [&](double first) {
            if (first >= earliest) {
                return first;
            }
            return first + std::ceil((earliest - first) / half) * half;
        };

        const double previous_target = timeline->real_target.load(std::memory_order_relaxed);
        double anchor = previous_target;
        if (timeline->real_actual_for.load(std::memory_order_relaxed) == previous_target) {
            const double actual = timeline->real_actual.load(std::memory_order_relaxed);
            if (actual > 0.0) {
                anchor = actual;
            }
        }
        if (anchor < now - 0.1 || anchor > now + 0.2) {
            anchor = 0.0; // After a pause or a stretch without frame generation
        }

        double made_time = 0.0;
        double real_time = 0.0;
        bool on_refresh = anchor > 0.0;
        if (on_refresh) {
            if (made) {
                made_time = refresh(anchor + half);
                real_time = made_time + half;
                if (made_time - earliest > half + tick60 * 0.75) {
                    // Far ahead of the game (after a hitch): leave the made frame out once, which
                    // takes half a frame of delay away again.
                    real_time = made_time;
                    made = false;
                } else if (made_time - arrived > interval + 3.0 * tick60) {
                    on_refresh = false; // Not plausible, start over
                }
            } else {
                real_time = refresh(anchor + 2.0 * half);
            }
        }
        if (!on_refresh) {
            made_time = earliest;
            real_time = made ? made_time + half : now;
        }
        // The display shows a frame at the first refresh at or after the time it is given.
        const double guard = on_refresh ? 0.003 : 0.0;

        if (made) {
            const double late_after = made_time + 0.004;
            [drawable_between addPresentedHandler:^(id<MTLDrawable> presented) {
              const double shown = presented.presentedTime;
              RecordPresentedTime(shown);
              AdjustLead(*timeline, on_refresh && (shown <= 0.0 || shown > late_after));
            }];
            [buffer presentDrawable:drawable_between atTime:made_time - guard];
        } else if (drawable_between != nil) {
            // Taken but left out: it goes back to the layer unshown.
            drawable_between = nil;
        }
        if (drawable_current != nil) {
            const double real_late_after = real_time + 0.004;
            const bool real_on_refresh = on_refresh && real_time > now;
            [drawable_current addPresentedHandler:^(id<MTLDrawable> presented) {
              const double shown = presented.presentedTime;
              RecordPresentedTime(shown);
              if (real_on_refresh) {
                  AdjustLead(*timeline, shown <= 0.0 || shown > real_late_after);
              }
              if (shown > 0.0) {
                  timeline->real_actual.store(shown, std::memory_order_relaxed);
                  timeline->real_actual_for.store(real_time, std::memory_order_relaxed);
              }
            }];
            if (real_time > now) {
                [buffer presentDrawable:drawable_current atTime:real_time - guard];
            } else {
                [buffer presentDrawable:drawable_current];
            }
            timeline->real_target.store(real_time, std::memory_order_relaxed);
        }
        [buffer commit];
        busy->store(false, std::memory_order_release);
    });

    // Once the GPU has the picture in the planes, the interpolation makes the frame between the
    // previous one and this one; without a previous frame only this one is shown.
    [scheduler.CommandBuffer() addCompletedHandler:^(id<MTLCommandBuffer>) {
      if (!make_between) {
          (*show)(false);
          return;
      }
      const auto start = std::chrono::steady_clock::now();
      const bool started = interpolate(previous, source, destination, [show, start,
                                                                      failures](bool ok) {
          if (ok) {
              const auto took = std::chrono::steady_clock::now() - start;
              Stats().fg_ns.fetch_add(
                  static_cast<u64>(
                      std::chrono::duration_cast<std::chrono::nanoseconds>(took).count()),
                  std::memory_order_relaxed);
              Stats().fg_made.fetch_add(1, std::memory_order_relaxed);
              failures->store(0, std::memory_order_relaxed);
          } else {
              failures->fetch_add(1, std::memory_order_relaxed);
          }
          (*show)(ok);
      });
      if (!started) {
          (*show)(false);
      }
    }];
    scheduler.Flush();

    fg_prev = static_cast<int>(fg_cur);
    fg_cur = (fg_cur + 1) % FG_SLOTS;
}

void RendererMetal::RenderScreenshot() {
    if (!settings.screenshot_requested.exchange(false)) {
        return;
    }

    const Layout::FramebufferLayout layout{settings.screenshot_framebuffer_layout};
    const u32 width = layout.width;
    const u32 height = layout.height;
    if (width == 0 || height == 0 || !settings.screenshot_bits) {
        // The callback's argument is "invert Y" for the frontends, so a failure can't be reported
        // through it: the request is dropped.
        LOG_ERROR(Render, "Dropping a screenshot request with an invalid layout or buffer");
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
        // The image is already top-down, it does not have to be inverted.
        settings.screenshot_complete_callback(false);
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
    fg_swaps++;

    // A frame with a draw that was skipped (shader still being built) would show up with parts
    // missing for a moment: keep the previous frame instead.
    bool hold_frame = false;
    if (Stats().frame_skipped.exchange(0, std::memory_order_relaxed) > 0 &&
        GetQualityOptions().hold_frames_for_shaders && held_frames < 3) {
        hold_frame = true;
        ++held_frames;
    } else {
        held_frames = 0;
    }

    if (!hold_frame && (!Settings::values.use_skip_duplicate_frames.GetValue() ||
                        Core::PerfStats::game_frames_updated)) {
        if (layer_dirty) {
            AcquireLayer();
        }
        RenderToLayer(layer, layout, true);
        // The secondary window (an external display) shows the other part of the layout.
        if (secondary_window != nullptr) {
            if (second_layer_dirty) {
                second_layer_dirty = false;
                second_layer = ConfigureLayer(secondary_window->GetWindowInfo().render_surface);
            }
            if (second_layer != nil) {
                RenderToLayer(second_layer, secondary_window->GetFramebufferLayout(), false);
            }
        }
        Core::PerfStats::game_frames_updated = false;
    }

    scheduler.Flush();
    LimitFramesAheadOfGpu();
    Stats().frames.fetch_add(1, std::memory_order_relaxed);

    system.perf_stats->EndSwap();
    rasterizer.TickFrame();
    EndFrame();
}

} // Anonymous namespace

QualityOptions g_quality_options;

void SetFrameGeneratorHooks(FrameGeneratorHooks hooks) {
    g_fg_hooks = std::move(hooks);
}

void SetQualityOptions(const QualityOptions& options) {
    g_quality_options = options;
}

const QualityOptions& GetQualityOptions() {
    return g_quality_options;
}

FrameStats TakeFrameStats() {
    GpuStats& stats = Stats();
    FrameStats result;
    result.frames = stats.frames.exchange(0);
    const u64 gpu_ns = stats.gpu_ns.exchange(0);
    const u64 present_ns = stats.present_ns.exchange(0);
    const u64 stall_ns = stats.stall_ns.exchange(0);
    const u32 stalls = stats.stalls.exchange(0);
    const u32 draws = stats.draws.exchange(0);
    const u32 skipped = stats.skipped.exchange(0);
    const u32 render_passes = stats.render_passes.exchange(0);
    const u32 blit_passes = stats.blit_passes.exchange(0);
    const u32 feedback_copies = stats.feedback_copies.exchange(0);
    const u64 drawable_ns = stats.drawable_ns.exchange(0);
    const u32 intervals = stats.present_intervals.exchange(0);
    const u64 interval_us = stats.present_interval_us.exchange(0);
    const u64 interval_sq_us = stats.present_interval_sq_us.exchange(0);
    result.present_late = static_cast<double>(stats.present_late.exchange(0));
    const u64 fg_ns = stats.fg_ns.exchange(0);
    const u32 fg_made = stats.fg_made.exchange(0);
    result.fg_made = static_cast<double>(fg_made);
    result.fg_skipped = static_cast<double>(stats.fg_skipped.exchange(0));
    result.fg_late = static_cast<double>(stats.fg_late.exchange(0));
    result.fg_lead_ms = static_cast<double>(stats.fg_lead_us.load()) / 1000.0;
    if (fg_made > 0) {
        result.fg_ms = static_cast<double>(fg_ns) / 1e6 / fg_made;
    }
    if (intervals > 1) {
        const double n = static_cast<double>(intervals);
        const double mean = static_cast<double>(interval_us) / n;
        const double variance =
            std::max(0.0, static_cast<double>(interval_sq_us) / n - mean * mean);
        result.present_interval_ms = mean / 1000.0;
        result.present_jitter_ms = std::sqrt(variance) / 1000.0;
    }
    if (result.frames > 0) {
        const double frames = static_cast<double>(result.frames);
        result.gpu_ms = static_cast<double>(gpu_ns) / 1e6 / frames;
        result.present_ms = static_cast<double>(present_ns) / 1e6 / frames;
        result.stall_ms = static_cast<double>(stall_ns) / 1e6 / frames;
        result.stalls = static_cast<double>(stalls) / frames;
        result.draws = static_cast<double>(draws) / frames;
        result.skipped = static_cast<double>(skipped) / frames;
        result.render_passes = static_cast<double>(render_passes) / frames;
        result.blit_passes = static_cast<double>(blit_passes) / frames;
        result.feedback_copies = static_cast<double>(feedback_copies) / frames;
        result.drawable_ms = static_cast<double>(drawable_ns) / 1e6 / frames;
    }
    return result;
}

void SetPostProcessing(int effect, int anaglyph_mode) {
    g_post_effect.store(effect, std::memory_order_relaxed);
    g_anaglyph_mode.store(anaglyph_mode, std::memory_order_relaxed);
}

void SetCustomPostShader(const std::string& path) {
    std::scoped_lock lock{g_custom_post_mutex};
    g_custom_post_path = path;
}

void SetUpscalerMode(UpscalerMode mode) {
    g_upscaler_mode.store(static_cast<int>(mode), std::memory_order_relaxed);
}

bool IsUpscalingSupported() {
#if AZAHAR_HAS_METALFX
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device != nil && MetalFXSupported(device);
#else
    return false;
#endif
}

std::unique_ptr<VideoCore::RendererBase> CreateRenderer(Core::System& system, Pica::PicaCore& pica,
                                                        Frontend::EmuWindow& window,
                                                        Frontend::EmuWindow* secondary_window) {
    return std::make_unique<RendererMetal>(system, pica, window, secondary_window);
}

} // namespace Metal
