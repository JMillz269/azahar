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
    @State private var clearedShaderCache = false

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

            Section {
                Picker("Internal Resolution", selection: $settings.resolutionFactor) {
                    ForEach(1...6, id: \.self) { factor in
                        Text(factor == 1 ? "Native (1x)" : "\(factor)x").tag(factor)
                    }
                }
                Toggle("Linear Screen Filtering", isOn: $settings.linearFiltering)
                Picker("Texture Filter", selection: $settings.textureFilter) {
                    ForEach(TextureFilterOption.allCases) { Text($0.title).tag($0) }
                }
                Picker("Anisotropic Filtering", selection: $settings.anisotropy) {
                    Text("Off").tag(1)
                    ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)x").tag($0) }
                }
                Toggle("Fast Shader Math", isOn: $settings.fastShaderMath)
                Toggle("Fast Lighting Math", isOn: $settings.fastLighting)
            } header: {
                Text("Enhancements")
            } footer: {
                Text("Texture filters smooth the textures of games when Internal Resolution is above "
                     + "1x (xBRZ and MMPX suit pixel art, Bicubic and ScaleForce are gentler). "
                     + "Lower anisotropic filtering and Fast Shader Math make games run faster. "
                     + "Fast Shader Math can cause small graphical differences in some games. "
                     + "Fast Lighting Math computes lighting in half precision, which helps games "
                     + "with a lot of lighting (Luigi's Mansion) and can shift highlights slightly. "
                     + "All of these apply the next time a game starts.")
            }

            Section {
                Toggle("Use External Display", isOn: $settings.useExternalDisplay)
            } header: {
                Text("External Display")
            } footer: {
                Text("With a TV or AirPlay display connected, it shows the top screen and this device "
                     + "the bottom screen with the controls. Takes effect when a game starts. "
                     + "Running inside another app (such as LiveContainer) may stop iOS from "
                     + "offering the display to Azahar.")
            }

            Section {
                Toggle("Custom Textures", isOn: $settings.customTextures)
                Toggle("Preload Custom Textures", isOn: $settings.preloadTextures)
                    .disabled(!settings.customTextures)
                Toggle("Dump Textures", isOn: $settings.dumpTextures)
            } header: {
                Text("Texture Packs")
            } footer: {
                Text("Custom Textures replaces the textures of a game with the images in Files › "
                     + "Azahar › load › textures › the game's title ID. Preloading loads them all "
                     + "when the game starts (more memory, no stutter). Dump Textures saves the "
                     + "textures a game uses to Files › Azahar › dump › textures, to make a pack. "
                     + "Applies the next time a game starts.")
            }

            Section {
                Picker("Outer Cameras", selection: $settings.outerCamera) {
                    ForEach(CameraSource.allCases) { Text($0.title).tag($0) }
                }
                Picker("Inner Camera", selection: $settings.innerCamera) {
                    ForEach(CameraSource.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Cameras")
            } footer: {
                Text("Choose which camera of this device a camera of the 3DS shows. Off shows a "
                     + "black picture. The first time a game uses a camera, iOS asks for "
                     + "permission. Applies the next time a game starts.")
            }

            Section {
                Picker("3D Mode", selection: $settings.stereoMode) {
                    ForEach(StereoModeOption.allCases) { Text($0.title).tag($0) }
                }
                if settings.stereoMode != .off {
                    VStack(alignment: .leading) {
                        Text("Depth: \(settings.stereoDepth)%")
                        Slider(value: Binding(
                            get: { Double(settings.stereoDepth) },
                            set: { settings.stereoDepth = Int($0.rounded()) }), in: 0...100)
                    }
                    Toggle("Swap Eyes", isOn: $settings.swapEyes3D)
                }
            } header: {
                Text("3D")
            } footer: {
                Text("Anaglyph needs red/cyan glasses. Interlaced shows the eyes on alternate rows "
                     + "of the screen. These modes don't use MetalFX.")
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

            Section {
                Toggle("Frame Pacing", isOn: $settings.framePacing)
                Picker("Display Refresh Rate", selection: $settings.refreshRate) {
                    ForEach(RefreshRateOption.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Smoothness")
            } footer: {
                Text("Frame Pacing shows each frame for the same amount of time, which makes motion "
                     + "look smoother, most on displays that refresh faster than the game. It does "
                     + "not apply while fast-forwarding. Display Refresh Rate asks ProMotion displays to run at "
                     + "60 Hz (saves power, one refresh per game frame) or up to 120 Hz; games run "
                     + "at 60 frames per second either way. iOS may ignore the request, especially "
                     + "when the app runs inside another app. The performance overlay's Pace value is "
                     + "how much the time between frames varies (lower is smoother). Applies "
                     + "when a game starts.")
            }

            Section {
                Toggle("Async Shader Compilation", isOn: $settings.asyncShaders)
                Toggle("Disk Shader Cache", isOn: $settings.diskShaderCache)
                Button("Clear Shader Cache", role: .destructive) {
                    clearedShaderCache = FileLocations.clearShaderCache()
                }
            } header: {
                Text("Shaders")
            } footer: {
                Text("Async Shader Compilation builds new shaders in the background instead of "
                     + "pausing the game, an object may be missing for a moment instead. The disk "
                     + "shader cache remembers the shaders of each game and builds them while it "
                     + "boots, so they don't need to be built again during play.")
            }
            .alert("Shader Cache Cleared", isPresented: $clearedShaderCache) {
                Button("OK", role: .cancel) {}
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
            Section {
                Picker("Screen Layout", selection: $settings.layout) {
                    ForEach(ScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Landscape")
            } footer: {
                if settings.layout == .custom {
                    Text("Place the screens with Edit Screen Layout in the menu while a game runs.")
                }
            }
            Section {
                Picker("Screen Layout", selection: $settings.portraitLayout) {
                    ForEach(PortraitScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Portrait")
            } footer: {
                if settings.portraitLayout == .custom {
                    Text("Place the screens with Edit Screen Layout in the menu while a game runs.")
                }
            }
            Section {
                Toggle("Swap Screens", isOn: $settings.swapScreens)
                Toggle("Upright Screens", isOn: $settings.uprightScreens)
                Stepper("Screen Gap: \(settings.screenGap)", value: $settings.screenGap,
                        in: 0...200, step: 5)
                if settings.layout == .largeScreen {
                    VStack(alignment: .leading) {
                        Text(String(format: "Large Screen Size: %.1fx", settings.largeScreenProportion))
                        Slider(value: $settings.largeScreenProportion, in: 1...16, step: 0.5)
                    }
                    Picker("Small Screen Position", selection: $settings.smallScreenPlacement) {
                        ForEach(SmallScreenPlacement.allCases) { Text($0.title).tag($0) }
                    }
                }
            } footer: {
                Text("Upright Screens turns the screens on their side. Screen Gap applies to the "
                     + "layouts that have a gap, the large screen options to the Large Screen "
                     + "layout.")
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
                Toggle("Use Microphone", isOn: $settings.useMicrophone)
            } footer: {
                Text("Audio stretching reduces stuttering when the emulation runs below full speed. "
                     + "Use Microphone lets games listen to the microphone of this device (it asks "
                     + "for permission when a game starts). Without it games hear static noise. "
                     + "Applies when a game starts.")
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
                Toggle("Hide When a Controller Is Connected",
                       isOn: $settings.hideControllerWithHardware)
                    .disabled(!settings.showController)
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
                NavigationLink("Controller Mapping") { ControllerMappingView() }
                Text("MFi, Xbox, PlayStation and Switch controllers are detected automatically. "
                     + "By default the face buttons are mapped by position like on a Nintendo "
                     + "console. Controller Mapping changes that and adds shortcuts.")
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
