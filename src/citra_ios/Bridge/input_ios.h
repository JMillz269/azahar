// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <string>

/// Input devices fed by the iOS frontend (on-screen controller, game controllers, CoreMotion).
namespace IOSInput {

constexpr const char* ENGINE = "ios";
constexpr const char* MOTION_ENGINE = "ios_motion";

/// Registers the input factories and binds the 3DS controls to them.
void Init();
void Shutdown();

void SetButton(int button, bool pressed);
void SetAnalog(int analog, float x, float y);
void SetMotion(float ax, float ay, float az, float gx, float gy, float gz);

/// Points the current input profile at the iOS input devices.
void BindInputProfile();

} // namespace IOSInput
