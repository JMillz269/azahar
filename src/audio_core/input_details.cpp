// Copyright 2023-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <algorithm>
#include <atomic>
#include <memory>
#include <string>
#include <vector>
#include "audio_core/input_details.h"
#include "audio_core/null_input.h"
#include "audio_core/static_input.h"
#ifdef HAVE_CUBEB
#include "audio_core/cubeb_input.h"
#endif
#ifdef HAVE_OPENAL
#include "audio_core/openal_input.h"
#endif
#ifdef HAVE_LIBRETRO
#include "audio_core/libretro_input.h"
#endif
#include "common/logging/log.h"
#include "core/core.h"

namespace AudioCore {
namespace {
#ifdef HAVE_CUSTOM_INPUT
std::atomic<InputDetails::FactoryFn> g_custom_input_factory{nullptr};
#endif

// input_details is ordered in terms of desirability, with the best choice at the top.
constexpr std::array input_details = {
#ifdef HAVE_CUSTOM_INPUT
    InputDetails{InputType::Custom, "Device Microphone", true,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     const auto factory = g_custom_input_factory.load();
                     if (factory == nullptr || !system.HasMicPermission()) {
                         LOG_WARNING(Audio, "No microphone available, falling back to null input.");
                         return std::make_unique<NullInput>();
                     }
                     return factory(system, device_id);
                 },
                 [] { return std::vector<std::string>{"Default Microphone"}; }},
#endif
#ifdef HAVE_LIBRETRO
    InputDetails{InputType::LibRetro, "Real Device (LibRetro)", true,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     if (!system.HasMicPermission()) {
                         LOG_WARNING(Audio,
                                     "Microphone permission denied, falling back to null input.");
                         return std::make_unique<NullInput>();
                     }
                     return std::make_unique<LibRetroInput>();
                 },
                 [] { return std::vector<std::string>{"LibRetro Microphone"}; }},
#endif
#ifdef HAVE_CUBEB
    InputDetails{InputType::Cubeb, "Real Device (Cubeb)", true,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     if (!system.HasMicPermission()) {
                         LOG_WARNING(Audio,
                                     "Microphone permission denied, falling back to null input.");
                         return std::make_unique<NullInput>();
                     }
                     return std::make_unique<CubebInput>(std::string(device_id));
                 },
                 &ListCubebInputDevices},
#endif
#ifdef HAVE_OPENAL
    InputDetails{InputType::OpenAL, "Real Device (OpenAL)", true,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     if (!system.HasMicPermission()) {
                         LOG_WARNING(Audio,
                                     "Microphone permission denied, falling back to null input.");
                         return std::make_unique<NullInput>();
                     }
                     return std::make_unique<OpenALInput>(std::string(device_id));
                 },
                 &ListOpenALInputDevices},
#endif
    InputDetails{InputType::Static, "Static Noise", false,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     return std::make_unique<StaticInput>();
                 },
                 [] { return std::vector<std::string>{"Static Noise"}; }},
    InputDetails{InputType::Null, "None", false,
                 [](Core::System& system, std::string_view device_id) -> std::unique_ptr<Input> {
                     return std::make_unique<NullInput>();
                 },
                 [] { return std::vector<std::string>{"None"}; }},
};
} // Anonymous namespace

void SetCustomInputFactory([[maybe_unused]] InputDetails::FactoryFn factory) {
#ifdef HAVE_CUSTOM_INPUT
    g_custom_input_factory.store(factory);
#endif
}

std::vector<InputDetails> ListInputs() {
    return {input_details.begin(), input_details.end()};
}

const InputDetails& GetInputDetails(InputType input_type) {
    auto iter = std::find_if(
        input_details.begin(), input_details.end(),
        [input_type](const auto& input_detail) { return input_detail.type == input_type; });

    if (input_type == InputType::Auto || iter == input_details.end()) {
        if (input_type != InputType::Auto) {
            LOG_ERROR(Audio, "AudioCore::GetInputDetails given invalid input_type {}", input_type);
        }
        // Auto-select.
        // input_details is ordered in terms of desirability, with the best choice at the front.
        iter = input_details.begin();
    }

    return *iter;
}

} // namespace AudioCore
