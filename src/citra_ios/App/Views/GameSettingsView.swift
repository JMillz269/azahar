// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

/// The settings of one game. Every row can use the global setting or replace it for this game.
struct GameSettingsView: View {
    let game: Game
    @ObservedObject private var store = GameOverridesStore.shared
    @State private var overrides = GameOverrides()

    var body: some View {
        Form {
            Section {
                OverridePicker("Internal Resolution", value: $overrides.resolutionFactor,
                               options: Array(1...6)) { $0 == 1 ? "Native (1x)" : "\($0)x" }
                OverridePicker("Texture Filter", value: $overrides.textureFilter,
                               options: TextureFilterOption.allCases.map(\.rawValue)) {
                    TextureFilterOption(rawValue: $0)?.title ?? "\($0)"
                }
                OverridePicker("MetalFX Upscaling", value: $overrides.upscaling,
                               options: UpscalingOption.allCases.map(\.rawValue)) {
                    UpscalingOption(rawValue: $0)?.title ?? "\($0)"
                }
                OverridePicker("Anisotropic Filtering", value: $overrides.anisotropy,
                               options: [1, 2, 4, 8, 16]) { $0 == 1 ? "Off" : "\($0)x" }
                OverrideToggle("Fast Shader Math", value: $overrides.fastShaderMath)
                OverrideToggle("Fast Lighting Math", value: $overrides.fastLighting)
                OverrideToggle("Hardware Shaders", value: $overrides.hardwareShaders)
                OverridePicker("3D Mode", value: $overrides.stereoMode,
                               options: StereoModeOption.allCases.map(\.rawValue)) {
                    StereoModeOption(rawValue: $0)?.title ?? "\($0)"
                }
            } header: {
                Text("Graphics")
            }

            Section {
                OverridePicker("CPU Clock Speed", value: $overrides.cpuClockPercentage,
                               options: [50, 75, 100, 150, 200, 300, 400]) { "\($0)%" }
                OverridePicker("Speed Limit", value: $overrides.speedLimit,
                               options: [0, 50, 75, 100, 150, 200, 300]) {
                    $0 == 0 ? "No limit" : "\($0)%"
                }
            } header: {
                Text("Speed")
            }

            Section {
                OverrideToggle("New 3DS Mode", value: $overrides.isNew3DS)
                OverridePicker("Region", value: $overrides.region,
                               options: ConsoleRegion.allCases.map(\.rawValue)) {
                    ConsoleRegion(rawValue: $0)?.title ?? "\($0)"
                }
            } header: {
                Text("System")
            } footer: {
                Text("Rows set to Default follow the global settings. Changes apply the next time "
                     + "the game starts.")
            }

            Section {
                Button("Reset to Global Settings", role: .destructive) {
                    overrides = GameOverrides()
                }
                .disabled(overrides.isEmpty)
            }
        }
        .navigationTitle("Game Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { overrides = store.overrides(for: game) }
        .onChange(of: overrides) { store.set($0, for: game) }
    }
}

/// A picker that can also fall back to the global setting (nil).
private struct OverridePicker: View {
    let title: String
    @Binding var value: Int?
    let options: [Int]
    let label: (Int) -> String

    init(_ title: String, value: Binding<Int?>, options: [Int], label: @escaping (Int) -> String) {
        self.title = title
        _value = value
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $value) {
            Text("Default").tag(Int?.none)
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(Int?.some(option))
            }
        }
    }
}

/// A switch with three states: the global setting, on and off.
private struct OverrideToggle: View {
    let title: String
    @Binding var value: Bool?

    init(_ title: String, value: Binding<Bool?>) {
        self.title = title
        _value = value
    }

    var body: some View {
        Picker(title, selection: $value) {
            Text("Default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }
}
