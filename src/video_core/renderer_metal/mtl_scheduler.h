// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <utility>
#include <vector>
#include "video_core/renderer_metal/mtl_common.h"

namespace Metal {

class Instance;

/// Counters of what the GPU and the emulation thread spent time on, see TakeFrameStats.
struct GpuStats {
    std::atomic<u64> gpu_ns{};     ///< GPU execution time of the command buffers
    std::atomic<u64> present_ns{}; ///< Part of gpu_ns spent in the presentation (MetalFX, screens)
    std::atomic<u64> stall_ns{};   ///< Time the emulation thread waited for the GPU
    std::atomic<u32> stalls{};     ///< Number of those waits
    std::atomic<u32> draws{};      ///< Draw calls
    std::atomic<u32> skipped{};    ///< Draws skipped because their pipeline was not built yet
    std::atomic<u32> frames{};     ///< Presented frames
};

GpuStats& Stats();

/// Describes the attachments of a render pass.
struct RenderTarget {
    id<MTLTexture> color = nil;
    u32 color_level = 0;
    u32 color_slice = 0;
    id<MTLTexture> depth = nil;
    u32 depth_level = 0;
    bool has_stencil = false;
    /// Render area size, the intersection of the attachment sizes.
    u32 width = 0;
    u32 height = 0;

    bool operator==(const RenderTarget& other) const noexcept {
        return color == other.color && color_level == other.color_level &&
               color_slice == other.color_slice && depth == other.depth &&
               depth_level == other.depth_level && has_stencil == other.has_stencil &&
               width == other.width && height == other.height;
    }
};

/**
 * Records Metal commands on the GPU thread. Command buffers are identified by monotonically
 * increasing ticks which are used to know when resources (stream buffer regions, surfaces pending
 * deletion) are no longer in use by the GPU.
 */
class Scheduler {
public:
    explicit Scheduler(const Instance& instance);
    ~Scheduler();

    Scheduler(const Scheduler&) = delete;
    Scheduler& operator=(const Scheduler&) = delete;

    /// Returns the command buffer currently being recorded, creating it if needed.
    id<MTLCommandBuffer> CommandBuffer();

    /// Returns a blit encoder, ending any other active encoder.
    id<MTLBlitCommandEncoder> BlitEncoder();

    /**
     * Returns a render encoder for the provided target. If the same target is already being
     * rendered to, the active encoder is reused. Attachments are loaded and stored.
     */
    id<MTLRenderCommandEncoder> BeginRendering(const RenderTarget& target);

    /// Begins a render pass using a custom descriptor (clears, presentation). Always starts a new
    /// encoder.
    id<MTLRenderCommandEncoder> BeginRendering(MTLRenderPassDescriptor* descriptor);

    /// Returns the active render encoder or nil.
    id<MTLRenderCommandEncoder> RenderEncoder() const {
        return render_encoder;
    }

    /// Returns true if the provided target is the one being rendered to.
    bool IsRenderingTo(const RenderTarget& target) const {
        return render_encoder != nil && has_render_target && current_target == target;
    }

    /// Incremented every time a new render encoder begins. Used to rebind encoder state.
    u64 EncoderGeneration() const {
        return encoder_generation;
    }

    /// Ends the active encoder, if any.
    void EndEncoding();

    /// Schedules a drawable to be presented when the current command buffer is committed.
    void PresentDrawable(id<CAMetalDrawable> drawable);

    /// Commits the current command buffer to the GPU.
    void Flush();

    /// Marks the command buffer being recorded as the presentation one for GpuStats::present_ns.
    void MarkPresentation() {
        presentation_tick = current_tick;
    }

    /// Commits the current command buffer and waits for all GPU work to complete.
    void Finish();

    /// Waits until the command buffer with the provided tick has completed.
    void Wait(u64 tick);

    /// Returns true when the command buffer with the provided tick has completed.
    bool IsFree(u64 tick) const {
        return KnownGpuTick() >= tick;
    }

    /// Tick of the command buffer being recorded.
    u64 CurrentTick() const {
        return current_tick;
    }

    /// Tick of the latest command buffer known to have completed.
    u64 KnownGpuTick() const {
        return gpu_tick.load(std::memory_order_acquire);
    }

    /// Registers a callback invoked before a command buffer is committed.
    void RegisterOnSubmit(std::function<void()>&& func) {
        on_submit.emplace_back(std::move(func));
    }

    /// Pushes and pops a debug group on the active command buffer.
    void PushDebugGroup(std::string_view label);
    void PopDebugGroup();

private:
    void PruneInFlight();

private:
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> command_buffer = nil;
    id<MTLRenderCommandEncoder> render_encoder = nil;
    id<MTLBlitCommandEncoder> blit_encoder = nil;
    RenderTarget current_target{};
    bool has_render_target{};
    u64 encoder_generation{};
    u64 current_tick{1};
    u64 presentation_tick{};
    std::atomic<u64> gpu_tick{0};
    std::deque<std::pair<u64, id<MTLCommandBuffer>>> in_flight;
    std::vector<std::function<void()>> on_submit;
    std::vector<id<CAMetalDrawable>> pending_drawables;
    u32 debug_group_depth{};
};

} // namespace Metal
