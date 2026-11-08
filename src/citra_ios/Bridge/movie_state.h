// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <mutex>
#include <string>

/// The movie the next game starts with (set through the Features category of AZEmulator, read when
/// the emulation thread boots a game).
struct PendingMovie {
    std::mutex mutex;
    std::string path;
    std::string author;
    int mode = 0; ///< 0 none, 1 record, 2 play
};

inline PendingMovie& GetPendingMovie() {
    static PendingMovie pending;
    return pending;
}
