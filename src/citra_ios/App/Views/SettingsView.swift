// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// Settings, grouped in categories.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { GeneralSettingsView() } label: {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink { GraphicsSettingsView() } label: {
                        Label("Graphics", systemImage: "display")
                    }
                    NavigationLink { LayoutSettingsView() } label: {
                        Label("Layout", systemImage: "rectangle.split.1x2")
                    }
                    NavigationLink { AudioSettingsView() } label: {
                        Label("Audio", systemImage: "speaker.wave.2")
                    }
                    NavigationLink { SystemSettingsView() } label: {
                        Label("System", systemImage: "cpu")
                    }
                    NavigationLink { ControlsSettingsView() } label: {
                        Label("Controls", systemImage: "gamecontroller")
                    }
                }
                Section {
                    NavigationLink { AboutView() } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct JITStatusRow: View {
    var body: some View {
        HStack {
            Text("JIT")
            Spacer()
            if AZEmulator.isJITAvailable {
                Label("Enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Unavailable", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                JITStatusRow()
                Toggle("CPU JIT", isOn: $settings.cpuJIT)
                    .disabled(!AZEmulator.isJITAvailable)
                Stepper(value: $settings.cpuClockPercentage, in: 25...400, step: 25) {
                    LabeledContent("CPU Clock", value: "\(settings.cpuClockPercentage)%")
                }
            } header: {
                Text("CPU")
            } footer: {
                Text("JIT recompilation requires the app to be launched with JIT enabled, for "
                     + "example through StikDebug or a debugger. Without JIT the much slower "
                     + "interpreter is used.")
            }

            Section("Speed") {
                Toggle("Limit Speed", isOn: $settings.useFrameLimit)
                if settings.useFrameLimit {
                    Stepper(value: $settings.frameLimit, in: 25...400, step: 25) {
                        LabeledContent("Speed Limit", value: "\(settings.frameLimit)%")
                    }
                }
            }

            Section("Library") {
                Picker("Library Style", selection: $settings.libraryStyle) {
                    ForEach(LibraryStyle.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .navigationTitle("General")
    }
}

struct GraphicsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Renderer", value: "Metal")
                Toggle("Hardware Shaders", isOn: $settings.hardwareShaders)
                Toggle("Accurate Multiplication", isOn: $settings.accurateMultiplication)
                    .disabled(!settings.hardwareShaders)
                Toggle("Shader JIT", isOn: $settings.shaderJIT)
                    .disabled(!AZEmulator.isJITAvailable)
            } header: {
                Text("Renderer")
            } footer: {
                Text("Azahar renders natively with Metal. Hardware Shaders run the game's vertex "
                     + "shaders on the GPU. Draws that can't be translated, and games that use "
                     + "geometry shaders, still run on the CPU, where the shader JIT speeds them "
                     + "up. Accurate Multiplication fixes graphical glitches in some games at a "
                     + "small GPU cost.")
            }

            Section("Enhancements") {
                Picker("Internal Resolution", selection: $settings.resolutionFactor) {
                    ForEach(1...6, id: \.self) { factor in
                        Text(factor == 1 ? "Native (1x)" : "\(factor)x").tag(factor)
                    }
                }
                Toggle("Linear Screen Filtering", isOn: $settings.linearFiltering)
            }

            Section {
                Picker("Upscaling", selection: $settings.upscaling) {
                    ForEach(UpscalingOption.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!AZEmulator.isUpscalingSupported)
            } header: {
                Text("MetalFX")
            } footer: {
                if AZEmulator.isUpscalingSupported {
                    Text("MetalFX Spatial scales each screen up to the size it is shown at with "
                         + "Apple's GPU upscaler, which looks sharper than plain filtering and "
                         + "lets you use a lower Internal Resolution (1x or 2x) for the same "
                         + "picture. It applies to the next frame, you do not need to restart.")
                } else {
                    Text("MetalFX is not available on this device.")
                }
            }

            Section("Performance") {
                Toggle("Skip Duplicate Frames", isOn: $settings.skipDuplicateFrames)
                Toggle("Show Performance Overlay", isOn: $settings.showPerformanceOverlay)
            }
        }
        .navigationTitle("Graphics")
    }
}

struct LayoutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Landscape") {
                Picker("Screen Layout", selection: $settings.layout) {
                    ForEach(ScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Portrait") {
                Picker("Screen Layout", selection: $settings.portraitLayout) {
                    ForEach(PortraitScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Swap Screens", isOn: $settings.swapScreens)
            }
            Section {
                Toggle("Respect Notch", isOn: $settings.respectNotch)
            } footer: {
                Text("Keeps the screens clear of the notch, the Dynamic Island and the rounded "
                     + "corners. Turn it off to draw the game edge to edge.")
            }
        }
        .navigationTitle("Layout")
    }
}

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Volume", value: "\(Int(settings.volume * 100))%")
                    Slider(value: $settings.volume, in: 0...1)
                }
                Toggle("Audio Stretching", isOn: $settings.audioStretching)
            } footer: {
                Text("Audio stretching reduces stuttering when the emulation runs below full speed.")
            }
        }
        .navigationTitle("Audio")
    }
}

struct SystemSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("New 3DS Mode", isOn: $settings.isNew3DS)
                Picker("Region", selection: $settings.region) {
                    ForEach(ConsoleRegion.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("System settings take effect the next time a game is started. Leave Region on "
                     + "Auto-select unless a game needs a specific one: a region that does not "
                     + "match the game (for example USA with a European copy) can stop it from "
                     + "booting.")
            }

            Section {
                LabeledContent("Data Folder", value: "Files › Azahar")
                LabeledContent("Games Folder", value: "Files › ROMs")
            } footer: {
                Text("System files, saves and the virtual SD card live in the Azahar folder of "
                     + "the app's documents, accessible from the Files app.")
            }
        }
        .navigationTitle("System")
    }
}

struct ControlsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var layout: ControllerLayoutStore
    @State private var confirmingLayoutReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Controller", isOn: $settings.showController)
                VStack(alignment: .leading) {
                    LabeledContent("Opacity", value: "\(Int(settings.controllerOpacity * 100))%")
                    Slider(value: $settings.controllerOpacity, in: 0.1...1)
                }
                Toggle("Haptic Feedback", isOn: $settings.hapticFeedback)
                Button("Reset Controller Layout", role: .destructive) {
                    confirmingLayoutReset = true
                }
            } header: {
                Text("On-Screen Controller")
            } footer: {
                Text("While playing, open the menu and choose Edit Controller Layout to move and "
                     + "resize the buttons.")
            }
            Section {
                Toggle("Motion Controls", isOn: $settings.useMotion)
            } footer: {
                Text("Uses the gyroscope and accelerometer for games that use motion controls.")
            }
            Section {
                Text("MFi, Xbox, PlayStation and Switch controllers are detected automatically. "
                     + "Face buttons are mapped by position like on a Nintendo console.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Game Controllers")
            }
        }
        .navigationTitle("Controls")
        .confirmationDialog("Reset the controller layout?", isPresented: $confirmingLayoutReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { layout.resetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every button goes back to its default position and size.")
        }
    }
}

struct AboutView: View {
    @State private var sharedLog: SharedFile?
    @State private var showingNoLog = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Azahar").font(.title.bold())
                    Text(AZEmulator.versionString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            Section {
                LabeledContent("Renderer", value: "Metal (native)")
                LabeledContent("JIT", value: AZEmulator.isJITAvailable ? "Available" : "Unavailable")
            }
            Section {
                Button {
                    if let url = LogExporter.makeShareableLog() {
                        sharedLog = SharedFile(url: url)
                    } else {
                        showingNoLog = true
                    }
                } label: {
                    Label("Share Log", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Shares the start and the end of the log and the last crash report, so the "
                     + "file stays small even when the full log is huge.")
            }
            Section {
                Text("Azahar is an open-source Nintendo 3DS emulator based on Citra. This iOS "
                     + "port uses a native Metal renderer. Azahar is licensed under the GPLv2. "
                     + "Only use games and system files dumped from hardware you own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .sheet(item: $sharedLog) { file in
            ShareSheet(url: file.url)
        }
        .alert("No Log Found", isPresented: $showingNoLog) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing has been logged yet.")
        }
    }
}
