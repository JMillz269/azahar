// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <functional>
#include <string>
#include "video_core/pica/shader_setup.h"

namespace Pica::Shader::Generator::MSL {

using RegGetter = std::function<std::string(u32)>;

/**
 * Translates a PICA shader program to MSL. The result declares the registers and defines
 * `bool exec_shader()` plus the subroutines it calls, all meant to be members of a struct that
 * also has a `constant PicaUniforms* uniforms` member and the members named by the register
 * getters. Returns an empty string if the program cannot be translated.
 */
std::string DecompileProgram(const Pica::ProgramCode& program_code,
                             const Pica::SwizzleData& swizzle_data, u32 main_offset,
                             const RegGetter& inputreg_getter, const RegGetter& outputreg_getter,
                             bool sanitize_mul);

} // namespace Pica::Shader::Generator::MSL
