// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

// Generates a corpus of MSL shaders covering the different code paths of the Metal shader
// generators. CI compiles the output with Apple's offline Metal compiler (xcrun metal) to catch
// generator regressions without needing a device.

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>

#include "video_core/pica/regs_internal.h"
#include "video_core/renderer_metal/mtl_utility_shaders.h"
#include "video_core/shader/generator/msl_shader_gen.h"

using namespace Pica::Shader;
using namespace Pica::Shader::Generator;

namespace {

Profile MakeMetalProfile() {
    Profile profile{};
    profile.has_separable_shaders = true;
    profile.has_clip_planes = true;
    profile.has_geometry_shader = false;
    profile.has_custom_border_color = false;
    profile.has_fragment_shader_interlock = true;
    profile.has_fragment_shader_barycentric = false;
    profile.has_blend_minmax_factor = false;
    profile.has_minus_one_to_one_range = false;
    profile.has_logic_op = false;
    profile.is_metal = true;
    return profile;
}

void Write(const std::filesystem::path& dir, const std::string& name, const std::string& source) {
    std::ofstream file{dir / name};
    file << source;
}

} // Anonymous namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <output dir> [random count]\n", argv[0]);
        return 1;
    }
    const std::filesystem::path out_dir{argv[1]};
    const int random_count = argc > 2 ? std::atoi(argv[2]) : 256;
    std::filesystem::create_directories(out_dir);

    const Profile profile = MakeMetalProfile();

    Write(out_dir, "utility.metal", std::string{Metal::Shaders::UTILITY});
    Write(out_dir, "utility_stencil.metal", std::string{Metal::Shaders::STENCIL});
    Write(out_dir, "present.metal", std::string{Metal::Shaders::PRESENT});

    Write(out_dir, "vs_trivial.metal", MSL::GenerateTrivialVertexShader(false));
    Write(out_dir, "vs_trivial_clip.metal", MSL::GenerateTrivialVertexShader(true));

    // Random register states exercise most of the generator branches.
    std::mt19937 rng{1234};
    int count = 0;
    for (int i = 0; i < random_count; i++) {
        Pica::RegsInternal regs{};
        auto* words = reinterpret_cast<u32*>(&regs);
        for (std::size_t w = 0; w < sizeof(regs) / sizeof(u32); w++) {
            words[w] = rng();
        }
        // Keep the lighting enabled half of the time and cap the number of lights.
        regs.lighting.disable.Assign(i % 2);
        regs.lighting.max_light_index.Assign(rng() % 8);

        const FSConfig config{regs};
        UserConfig user{};
        user.use_custom_normal.Assign(i % 7 == 0);

        MSL::MetalFSConfig metal_config{};
        metal_config.has_color_attachment = (i % 5) != 0;

        Write(out_dir, "fs_random_" + std::to_string(i) + ".metal",
              MSL::GenerateFragmentShader(config, user, profile, metal_config));
        count++;
    }

    // Default (all zero) register state.
    {
        Pica::RegsInternal regs{};
        const FSConfig config{regs};
        Write(out_dir, "fs_default.metal",
              MSL::GenerateFragmentShader(config, {}, profile, MSL::MetalFSConfig{}));
    }

    std::printf("Generated %d random fragment shaders into %s\n", count, out_dir.c_str());
    return 0;
}
