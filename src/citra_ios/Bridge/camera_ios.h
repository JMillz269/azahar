// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

namespace Camera {

/// Name of the camera factory in Settings::values.camera_name. The camera config is "back" or
/// "front".
constexpr const char* IOS_CAMERA_NAME = "ios";

/// Makes the device cameras available to the emulated console.
void RegisterIOSCameraFactory();

/// Orientation the cameras deliver upright frames in, depending on how the app is held.
void SetIOSCameraOrientation(bool landscape_left);

} // namespace Camera
