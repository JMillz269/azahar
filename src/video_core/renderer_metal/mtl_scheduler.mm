// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <algorithm>
#include <chrono>
#include "common/assert.h"
#include "common/logging/log.h"
#include "common/microprofile.h"
#include "video_core/renderer_metal/mtl_instance.h"
#include "video_core/renderer_metal/mtl_scheduler.h"

MICROPROFILE_DEFINE(Metal_WaitForGpu, "Metal", "Wait For GPU", MP_RGB(255, 0, 0));
MICROPROFILE_DEFINE(Metal_Submit, "Metal", "Submit", MP_RGB(255, 192, 255));

namespace Metal {

GpuStats& Stats() {
    static GpuStats stats;
    return stats;
}

Scheduler::Scheduler(const Instance& instance) : queue{instance.GetCommandQueue()} {}

Scheduler::~Scheduler() {
    Finish();
}

id<MTLCommandBuffer> Scheduler::CommandBuffer() {
    if (command_buffer == nil) {
        @autoreleasepool {
            command_buffer = [queue commandBuffer];
        }
        const u64 tick = current_tick;
        // The presentation gets a command buffer of its own, see RendererMetal::RenderToLayer.
        const bool is_presentation = tick == presentation_tick;
        std::atomic<u64>* gpu_tick_ptr = &gpu_tick;
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
          if (buffer.status == MTLCommandBufferStatusError) {
              LOG_CRITICAL(Render, "Metal command buffer {} failed: {}", tick,
                           [buffer.error.localizedDescription UTF8String]);
          }
          if (buffer.GPUEndTime > buffer.GPUStartTime) {
              const u64 ns = static_cast<u64>((buffer.GPUEndTime - buffer.GPUStartTime) * 1e9);
              Stats().gpu_ns.fetch_add(ns, std::memory_order_relaxed);
              if (is_presentation) {
                  Stats().present_ns.fetch_add(ns, std::memory_order_relaxed);
              }
          }
          u64 known = gpu_tick_ptr->load(std::memory_order_relaxed);
          while (known < tick &&
                 !gpu_tick_ptr->compare_exchange_weak(known, tick, std::memory_order_release)) {
          }
        }];
    }
    return command_buffer;
}

id<MTLBlitCommandEncoder> Scheduler::BlitEncoder() {
    if (blit_encoder != nil) {
        return blit_encoder;
    }
    EndEncoding();
    blit_encoder = [CommandBuffer() blitCommandEncoder];
    Stats().blit_passes.fetch_add(1, std::memory_order_relaxed);
    return blit_encoder;
}

id<MTLRenderCommandEncoder> Scheduler::BeginRendering(const RenderTarget& target) {
    if (IsRenderingTo(target)) {
        return render_encoder;
    }
    EndEncoding();

    MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    if (target.color != nil) {
        MTLRenderPassColorAttachmentDescriptor* color = descriptor.colorAttachments[0];
        color.texture = target.color;
        color.level = target.color_level;
        color.slice = target.color_slice;
        color.loadAction = MTLLoadActionLoad;
        color.storeAction = MTLStoreActionStore;
    }
    if (target.depth != nil) {
        MTLRenderPassDepthAttachmentDescriptor* depth = descriptor.depthAttachment;
        depth.texture = target.depth;
        depth.level = target.depth_level;
        depth.loadAction = MTLLoadActionLoad;
        depth.storeAction = MTLStoreActionStore;
        if (target.has_stencil) {
            MTLRenderPassStencilAttachmentDescriptor* stencil = descriptor.stencilAttachment;
            stencil.texture = target.depth;
            stencil.level = target.depth_level;
            stencil.loadAction = MTLLoadActionLoad;
            stencil.storeAction = MTLStoreActionStore;
        }
    }
    // The render area is the intersection of the attachments, which may have different sizes.
    descriptor.renderTargetWidth = std::max(target.width, 1u);
    descriptor.renderTargetHeight = std::max(target.height, 1u);
    if (target.color == nil && target.depth == nil) {
        // Attachment-less rendering, used for shadow map rendering.
        descriptor.defaultRasterSampleCount = 1;
    }

    render_encoder = [CommandBuffer() renderCommandEncoderWithDescriptor:descriptor];
    Stats().render_passes.fetch_add(1, std::memory_order_relaxed);
    current_target = target;
    has_render_target = true;
    encoder_generation++;
    return render_encoder;
}

id<MTLRenderCommandEncoder> Scheduler::BeginRendering(MTLRenderPassDescriptor* descriptor) {
    EndEncoding();
    render_encoder = [CommandBuffer() renderCommandEncoderWithDescriptor:descriptor];
    Stats().render_passes.fetch_add(1, std::memory_order_relaxed);
    has_render_target = false;
    encoder_generation++;
    return render_encoder;
}

void Scheduler::EndEncoding() {
    if (render_encoder != nil) {
        [render_encoder endEncoding];
        render_encoder = nil;
        has_render_target = false;
    }
    if (blit_encoder != nil) {
        [blit_encoder endEncoding];
        blit_encoder = nil;
    }
}

void Scheduler::PresentDrawable(id<CAMetalDrawable> drawable) {
    pending_drawables.push_back(drawable);
}

void Scheduler::PushDebugGroup(std::string_view label) {
    [CommandBuffer() pushDebugGroup:ToNSString(label)];
    debug_group_depth++;
}

void Scheduler::PopDebugGroup() {
    if (debug_group_depth == 0 || command_buffer == nil) {
        return;
    }
    [command_buffer popDebugGroup];
    debug_group_depth--;
}

void Scheduler::Flush() {
    MICROPROFILE_SCOPE(Metal_Submit);
    for (const auto& func : on_submit) {
        func();
    }
    EndEncoding();
    if (command_buffer == nil && pending_drawables.empty()) {
        return;
    }

    id<MTLCommandBuffer> buffer = CommandBuffer();
    while (debug_group_depth > 0) {
        [buffer popDebugGroup];
        debug_group_depth--;
    }
    for (id<CAMetalDrawable> drawable : pending_drawables) {
        [buffer presentDrawable:drawable];
    }
    pending_drawables.clear();
    [buffer commit];

    in_flight.emplace_back(current_tick, buffer);
    command_buffer = nil;
    current_tick++;
    PruneInFlight();
}

void Scheduler::Finish() {
    const u64 tick = current_tick;
    Flush();
    Wait(tick);
}

void Scheduler::Wait(u64 tick) {
    if (tick >= current_tick) {
        // The requested tick is still being recorded, submit it.
        Flush();
    }
    if (IsFree(tick)) {
        PruneInFlight();
        return;
    }

    MICROPROFILE_SCOPE(Metal_WaitForGpu);
    const auto wait_start = std::chrono::steady_clock::now();
    while (!in_flight.empty() && in_flight.front().first <= tick) {
        [in_flight.front().second waitUntilCompleted];
        in_flight.pop_front();
    }
    GpuStats& stats = Stats();
    stats.stall_ns.fetch_add(
        static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                             std::chrono::steady_clock::now() - wait_start)
                             .count()),
        std::memory_order_relaxed);
    stats.stalls.fetch_add(1, std::memory_order_relaxed);

    // Completion handlers may run slightly after waitUntilCompleted returns, make sure the known
    // tick reflects the wait.
    u64 known = gpu_tick.load(std::memory_order_relaxed);
    while (known < tick && !gpu_tick.compare_exchange_weak(known, tick)) {
    }
}

void Scheduler::PruneInFlight() {
    while (!in_flight.empty()) {
        const auto status = in_flight.front().second.status;
        if (status != MTLCommandBufferStatusCompleted && status != MTLCommandBufferStatusError) {
            break;
        }
        in_flight.pop_front();
    }
}

} // namespace Metal
