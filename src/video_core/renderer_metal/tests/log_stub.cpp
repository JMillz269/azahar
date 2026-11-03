// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

// Minimal logging backend so the MSL corpus generator can be built standalone.

#include <cstdio>
#include "common/logging/backend.h"
#include "common/logging/log.h"

namespace Common::Log {
void FmtLogMessageImpl(Class, Level, const char* filename, unsigned int line_num, const char*,
                       fmt::string_view format, const fmt::format_args& args) {
    std::fprintf(stderr, "%s:%u: %s\n", filename, line_num, fmt::vformat(format, args).c_str());
}
void Stop() {}
} // namespace Common::Log
