// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include "common/alignment.h"
#include "common/assert.h"
#include "common/logging/log.h"
#include "video_core/renderer_metal/mtl_instance.h"
#include "video_core/renderer_metal/mtl_scheduler.h"
#include "video_core/renderer_metal/mtl_stream_buffer.h"

namespace Metal {

namespace {
constexpr std::size_t WATCHES_INITIAL_RESERVE = 0x4000;
constexpr std::size_t WATCHES_RESERVE_CHUNK = 0x1000;
} // Anonymous namespace

StreamBuffer::StreamBuffer(const Instance& instance, Scheduler& scheduler_, u64 size,
                           std::string_view label, bool readback)
    : scheduler{scheduler_}, buffer_size{size} {
    const MTLResourceOptions options =
        MTLResourceStorageModeShared |
        (readback ? MTLResourceCPUCacheModeDefaultCache : MTLResourceCPUCacheModeWriteCombined);
    buffer = [instance.GetDevice() newBufferWithLength:size options:options];
    ASSERT_MSG(buffer, "Failed to allocate Metal stream buffer of {} KiB", size / 1024);
    SetLabel(buffer, label);
    mapped = static_cast<u8*>(buffer.contents);
    current_watches.resize(WATCHES_INITIAL_RESERVE);
    previous_watches.resize(WATCHES_INITIAL_RESERVE);
    LOG_INFO(Render, "Created Metal stream buffer '{}' with size {} KiB", label, size / 1024);
}

StreamBuffer::~StreamBuffer() = default;

std::tuple<u8*, u32, bool> StreamBuffer::Map(u32 size, u64 alignment) {
    ASSERT(size <= buffer_size);
    mapped_size = size;

    if (alignment > 0) {
        offset = static_cast<u32>(Common::AlignUp<u64>(offset, alignment));
    }

    bool invalidate{false};
    if (offset + size > buffer_size) {
        // The buffer would overflow, save the amount of used watches and reset the state.
        invalidate = true;
        invalidation_mark = current_watch_cursor;
        current_watch_cursor = 0;
        offset = 0;

        // Swap watches and reset waiting cursors.
        std::swap(previous_watches, current_watches);
        wait_cursor = 0;
        wait_bound = 0;
    }

    const u64 mapped_upper_bound = offset + size;
    WaitPendingOperations(mapped_upper_bound);

    return std::make_tuple(mapped + offset, offset, invalidate);
}

void StreamBuffer::Commit(u32 size) {
    ASSERT_MSG(size <= mapped_size, "Reserved size {} is too small compared to {}", mapped_size,
               size);
    offset += size;

    if (current_watch_cursor + 1 >= current_watches.size()) {
        current_watches.resize(current_watches.size() + WATCHES_RESERVE_CHUNK);
    }
    auto& watch = current_watches[current_watch_cursor++];
    watch.upper_bound = offset;
    watch.tick = scheduler.CurrentTick();
}

void StreamBuffer::WaitPendingOperations(u64 requested_upper_bound) {
    if (!invalidation_mark) {
        return;
    }
    while (requested_upper_bound > wait_bound && wait_cursor < *invalidation_mark) {
        auto& watch = previous_watches[wait_cursor];
        wait_bound = watch.upper_bound;
        scheduler.Wait(watch.tick);
        ++wait_cursor;
    }
}

} // namespace Metal
