// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <optional>
#include <tuple>
#include <vector>
#include "video_core/renderer_metal/mtl_common.h"

namespace Metal {

class Instance;
class Scheduler;

/**
 * Ring buffer in shared (unified) memory. The CPU writes into it directly and the GPU reads from
 * it. Regions are protected by the scheduler ticks of the command buffers that used them, so a
 * region is never overwritten while the GPU may still be reading it.
 */
class StreamBuffer final {
public:
    /// @param readback True if the CPU reads from the buffer (downloads), which disables
    ///                 write-combined CPU caching.
    explicit StreamBuffer(const Instance& instance, Scheduler& scheduler, u64 size,
                          std::string_view label, bool readback = false);
    ~StreamBuffer();

    /**
     * Reserves a region of memory from the stream buffer.
     * @returns A tuple of the raw memory pointer, the offset into the buffer and whether the
     *          buffer wrapped around (previous contents should be considered invalid).
     */
    std::tuple<u8*, u32, bool> Map(u32 size, u64 alignment);

    /// Marks the first "size" bytes of the last mapped region as used.
    void Commit(u32 size);

    id<MTLBuffer> Handle() const noexcept {
        return buffer;
    }

    u8* Mapped() const noexcept {
        return mapped;
    }

    u64 Size() const noexcept {
        return buffer_size;
    }

private:
    struct Watch {
        u64 tick{};
        u64 upper_bound{};
    };

    void WaitPendingOperations(u64 requested_upper_bound);

private:
    Scheduler& scheduler;
    id<MTLBuffer> buffer;
    u8* mapped{};
    u64 buffer_size{};
    u32 offset{};
    u32 mapped_size{};

    std::vector<Watch> current_watches;
    std::size_t current_watch_cursor{};
    std::optional<std::size_t> invalidation_mark;
    std::vector<Watch> previous_watches;
    std::size_t wait_cursor{};
    u64 wait_bound{};
};

} // namespace Metal
