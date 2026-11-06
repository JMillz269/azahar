# Native iOS app: a SwiftUI frontend on top of an Objective-C++ bridge to the emulator core.
# Requires the Xcode generator (cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS ...).

if (NOT CMAKE_GENERATOR STREQUAL "Xcode")
    message(FATAL_ERROR "The iOS app must be configured with the Xcode generator (-G Xcode)")
endif()

enable_language(Swift)

set(AZAHAR_IOS_DEPLOYMENT_TARGET "16.0")
set(AZAHAR_IOS_BUNDLE_ID "org.azahar-emu.azahar-ios" CACHE STRING "Bundle identifier of the iOS app")
# The increased memory limit entitlement needs a paid developer account (or a sideloading tool
# that preserves it). Disable it to sign with a free account from Xcode.
option(AZAHAR_IOS_ENTITLEMENTS "Request the increased memory limit entitlements" ON)

# ---------------------------------------------------------------------------------------------
# Objective-C++ bridge to the core, exposed to Swift as the "AzaharCore" clang module.
# ---------------------------------------------------------------------------------------------
set(BRIDGE_OBJCXX_SOURCES
    Bridge/AZConfiguration.mm
    Bridge/AZEmulator.mm
    Bridge/AZFeatures.mm
    Bridge/AZGameInfo.mm
)

add_library(azahar_ios_bridge STATIC
    ${BRIDGE_OBJCXX_SOURCES}
    Bridge/emu_window_ios.cpp
    Bridge/emu_window_ios.h
    Bridge/input_ios.cpp
    Bridge/input_ios.h
    Bridge/include/AzaharCore/AzaharCore.h
    Bridge/include/AzaharCore/AZConfiguration.h
    Bridge/include/AzaharCore/AZEmulator.h
    Bridge/include/AzaharCore/AZGameInfo.h
    Bridge/include/AzaharCore/module.modulemap
)

set_source_files_properties(${BRIDGE_OBJCXX_SOURCES} PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc"
    SKIP_PRECOMPILE_HEADERS ON
)

target_include_directories(azahar_ios_bridge
    PUBLIC Bridge/include
    PRIVATE ${PROJECT_SOURCE_DIR}/src
)

target_link_libraries(azahar_ios_bridge PRIVATE
    citra_common citra_core video_core audio_core input_common fmt
    "-framework Foundation" "-framework Metal" "-framework QuartzCore" "-weak_framework MetalFX"
)

set_target_properties(azahar_ios_bridge PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET ${AZAHAR_IOS_DEPLOYMENT_TARGET}
)

# ---------------------------------------------------------------------------------------------
# SwiftUI application
# ---------------------------------------------------------------------------------------------
set(APP_SWIFT_SOURCES
    App/AzaharApp.swift
    App/ContentView.swift
    App/Core/AppSettings.swift
    App/Core/ConsoleInput.swift
    App/Core/ControllerLayout.swift
    App/Core/DocumentImporter.swift
    App/Core/EmulationSession.swift
    App/Core/FileLocations.swift
    App/Core/GameLibrary.swift
    App/Core/LogExporter.swift
    App/Views/CheatsView.swift
    App/Views/ControllerOverlay.swift
    App/Views/EmulationView.swift
    App/Views/GameRowView.swift
    App/Views/GamesListView.swift
    App/Views/KeyboardPromptView.swift
    App/Views/MetalView.swift
    App/Views/SaveStatesView.swift
    App/Views/SettingsView.swift
)

add_executable(azahar_ios MACOSX_BUNDLE ${APP_SWIFT_SOURCES})

include(GenerateBuildInfo)
set(SRC_DIR "${PROJECT_SOURCE_DIR}")
generate_build_info()

set_target_properties(azahar_ios PROPERTIES
    OUTPUT_NAME "Azahar"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "Azahar"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${AZAHAR_IOS_BUNDLE_ID}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${BUILD_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${BUILD_FULLNAME}"
    MACOSX_BUNDLE_LONG_VERSION_STRING "${BUILD_FULLNAME}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${AZAHAR_IOS_BUNDLE_ID}"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET ${AZAHAR_IOS_DEPLOYMENT_TARGET}
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    XCODE_ATTRIBUTE_SWIFT_INCLUDE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}/Bridge/include"
    XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL "$<IF:$<CONFIG:Debug>,-Onone,-O>"
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks"
    XCODE_ATTRIBUTE_ENABLE_BITCODE NO
    XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING YES
)

if (AZAHAR_IOS_ENTITLEMENTS)
    set_target_properties(azahar_ios PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/Azahar.entitlements")
endif()

# The core is compiled with flags and definitions that only make sense for C/C++ (warnings,
# fortification, -stdlib=libc++, NAME=VALUE definitions). Keep them away from swiftc.
set_property(TARGET azahar_ios PROPERTY COMPILE_OPTIONS "")
set_property(TARGET azahar_ios PROPERTY COMPILE_DEFINITIONS "")
# src/ is a global include directory. On the case-insensitive macOS file system its
# network/network.h shadows the SDK's <Network/Network.h>, which breaks importing AVFoundation.
set_property(TARGET azahar_ios PROPERTY INCLUDE_DIRECTORIES "")

target_link_libraries(azahar_ios PRIVATE azahar_ios_bridge "-lc++")
