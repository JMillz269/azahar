// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

namespace AudioCore {

/// Makes the device microphone available as the emulated console's microphone (the Custom
/// input), and lets the core ask whether the app may record.
void RegisterIOSMicrophone();

} // namespace AudioCore
