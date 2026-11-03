// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <fmt/format.h>
#include "citra_ios/Bridge/input_ios.h"
#include "common/settings.h"
#include "core/frontend/input.h"

namespace IOSInput {

namespace {

struct ButtonState {
    std::array<std::atomic<bool>, Settings::NativeButton::NumButtons> pressed{};
};

struct AnalogState {
    struct Axis {
        std::atomic<float> x{0.0f};
        std::atomic<float> y{0.0f};
    };
    std::array<Axis, Settings::NativeAnalog::NumAnalogs> axes{};
};

struct MotionState {
    std::mutex mutex;
    Common::Vec3<float> accel{0.0f, -1.0f, 0.0f};
    Common::Vec3<float> gyro{};
};

ButtonState g_buttons;
AnalogState g_analogs;
MotionState g_motion;

class Button final : public Input::ButtonDevice {
public:
    explicit Button(int code_) : code{code_} {}
    bool GetStatus() const override {
        return g_buttons.pressed[code].load(std::memory_order_relaxed);
    }

private:
    int code;
};

class Analog final : public Input::AnalogDevice {
public:
    explicit Analog(int code_) : code{code_} {}
    std::tuple<float, float> GetStatus() const override {
        const auto& axis = g_analogs.axes[code];
        return {axis.x.load(std::memory_order_relaxed), axis.y.load(std::memory_order_relaxed)};
    }

private:
    int code;
};

class Motion final : public Input::MotionDevice {
public:
    std::tuple<Common::Vec3<float>, Common::Vec3<float>> GetStatus() const override {
        std::scoped_lock lock{g_motion.mutex};
        return {g_motion.accel, g_motion.gyro};
    }
};

class ButtonFactory final : public Input::Factory<Input::ButtonDevice> {
public:
    std::unique_ptr<Input::ButtonDevice> Create(const Common::ParamPackage& params) override {
        const int code = params.Get("code", 0);
        if (code < 0 || code >= Settings::NativeButton::NumButtons) {
            return std::make_unique<Input::ButtonDevice>();
        }
        return std::make_unique<Button>(code);
    }
};

class AnalogFactory final : public Input::Factory<Input::AnalogDevice> {
public:
    std::unique_ptr<Input::AnalogDevice> Create(const Common::ParamPackage& params) override {
        const int code = params.Get("code", 0);
        if (code < 0 || code >= Settings::NativeAnalog::NumAnalogs) {
            return std::make_unique<Input::AnalogDevice>();
        }
        return std::make_unique<Analog>(code);
    }
};

class MotionFactory final : public Input::Factory<Input::MotionDevice> {
public:
    std::unique_ptr<Input::MotionDevice> Create(const Common::ParamPackage&) override {
        return std::make_unique<Motion>();
    }
};

bool g_initialized = false;

} // Anonymous namespace

void Init() {
    if (g_initialized) {
        return;
    }
    Input::RegisterFactory<Input::ButtonDevice>(ENGINE, std::make_shared<ButtonFactory>());
    Input::RegisterFactory<Input::AnalogDevice>(ENGINE, std::make_shared<AnalogFactory>());
    Input::RegisterFactory<Input::MotionDevice>(MOTION_ENGINE, std::make_shared<MotionFactory>());
    g_initialized = true;
}

void Shutdown() {
    if (!g_initialized) {
        return;
    }
    Input::UnregisterFactory<Input::ButtonDevice>(ENGINE);
    Input::UnregisterFactory<Input::AnalogDevice>(ENGINE);
    Input::UnregisterFactory<Input::MotionDevice>(MOTION_ENGINE);
    g_initialized = false;
}

void BindInputProfile() {
    auto& profile = Settings::values.current_input_profile;
    for (int i = 0; i < Settings::NativeButton::NumButtons; i++) {
        profile.buttons[i] = fmt::format("engine:{},code:{}", ENGINE, i);
    }
    for (int i = 0; i < Settings::NativeAnalog::NumAnalogs; i++) {
        profile.analogs[i] = fmt::format("engine:{},code:{}", ENGINE, i);
    }
    profile.motion_device = fmt::format("engine:{}", MOTION_ENGINE);
    profile.touch_device = "engine:emu_window";
}

void SetButton(int button, bool pressed) {
    if (button >= 0 && button < Settings::NativeButton::NumButtons) {
        g_buttons.pressed[button].store(pressed, std::memory_order_relaxed);
    }
}

void SetAnalog(int analog, float x, float y) {
    if (analog >= 0 && analog < Settings::NativeAnalog::NumAnalogs) {
        g_analogs.axes[analog].x.store(x, std::memory_order_relaxed);
        g_analogs.axes[analog].y.store(y, std::memory_order_relaxed);
    }
}

void SetMotion(float ax, float ay, float az, float gx, float gy, float gz) {
    std::scoped_lock lock{g_motion.mutex};
    g_motion.accel = {ax, ay, az};
    g_motion.gyro = {gx, gy, gz};
}

} // namespace IOSInput
