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
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var compressor: GameCompressor

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

            Section {
                Toggle("Limit Speed", isOn: $settings.useFrameLimit)
                if settings.useFrameLimit {
                    Stepper(value: $settings.frameLimit, in: 25...400, step: 25) {
                        LabeledContent("Speed Limit", value: "\(settings.frameLimit)%")
                    }
                }
                Picker("Fast Forward Speed", selection: $settings.fastForwardSpeed) {
                    ForEach([150, 200, 300, 400, 500, 800], id: \.self) { Text("\($0)%").tag($0) }
                    Text("Unlimited").tag(0)
                }
                Toggle("Hold to Fast Forward (Controller)", isOn: $settings.fastForwardHold)
            } header: {
                Text("Speed")
            } footer: {
                Text("Fast Forward is in the game menu, and on a controller button in Controls › "
                     + "Controller Mapping. With Hold on, the controller button only fast-forwards "
                     + "while it is held.")
            }

            Section("Library") {
                Picker("Library Style", selection: $settings.libraryStyle) {
                    ForEach(LibraryStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Keep Original Files", isOn: $settings.keepOriginalsWhenCompressing)
                Button("Compress Games…") {
                    DocumentImporter.present { urls in
                        compressor.compress(urls, deleteSources: false, library: library)
                    }
                }
                .disabled(compressor.isRunning)
                Button("Compress the Games in the Library") {
                    compressor.compress(GameCompressor.compressibleFilesInLibrary(),
                                        deleteSources: !settings.keepOriginalsWhenCompressing,
                                        library: library)
                }
                .disabled(compressor.isRunning)
                if compressor.isRunning, let name = compressor.currentName {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(compressor.position) of \(compressor.total): \(name)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(value: compressor.progress)
                    }
                }
                Button("Show Games Folder in Files") {
                    FileLocations.showInFiles(FileLocations.romsDirectory)
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("Compressed games (.zcci, .zcxi, .z3dsx and .zcia) are smaller and play the "
                     + "same. They are written to the games folder (Files › ROMs). Compress the "
                     + "Games… picks files to compress, the originals you pick are left where "
                     + "they are; the library button compresses the games in the games folder "
                     + "and removes their originals unless Keep Original Files is on. A .zcia "
                     + "installs like a .cia. Encrypted and bundled games cannot be compressed.")
            }
        }
        .navigationTitle("General")
    }
}

struct GraphicsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var postShaders = PostShaders.availableNames()
    @State private var clearedShaderCache = false

    @ViewBuilder private var rendererSections: some View {
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
                Picker("Texture Sampling", selection: $settings.textureSampling) {
                    Text("Game Controlled").tag(0)
                    Text("Nearest Neighbor").tag(1)
                    Text("Linear").tag(2)
                }
                Picker("Texture Filter", selection: $settings.textureFilter) {
                    ForEach(TextureFilterOption.allCases) { Text($0.title).tag($0) }
                }
                Picker("Anisotropic Filtering", selection: $settings.anisotropy) {
                    Text("Off").tag(1)
                    ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)x").tag($0) }
                }
                Toggle("Fast Shader Math", isOn: $settings.fastShaderMath)
                Toggle("Fast Lighting Math", isOn: $settings.fastLighting)
                Toggle("Fast Color Math", isOn: $settings.fastColor)
                Toggle("Fast Depth Readback", isOn: $settings.fastDepthReadback)
                Toggle("Disable Right Eye Render", isOn: $settings.disableRightEyeRender)
                Toggle("Hidden Surface Removal", isOn: $settings.hiddenSurfaceRemoval)
                Picker("Texture Compression", selection: $settings.textureCompression) {
                    ForEach(TextureCompressionOption.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Enhancements")
            } footer: {
                Text("Texture filters smooth the textures of games when Internal Resolution is above "
                     + "1x (xBRZ and MMPX suit pixel art, Bicubic and ScaleForce are gentler). "
                     + "Lower anisotropic filtering and Fast Shader Math make games run faster. "
                     + "Fast Shader Math can cause small graphical differences in some games. "
                     + "Fast Lighting Math computes lighting in half precision, which helps games "
                     + "with a lot of lighting (Luigi's Mansion) and can shift highlights slightly. "
                     + "Fast Color Math does the color combiners in half precision, the same "
                     + "8-bit result in practice. Hidden Surface Removal lets the GPU skip "
                     + "pixels hidden behind others (not for games using W-buffering). Texture "
                     + "Compression saves GPU memory bandwidth: Lossless looks identical, Lossy "
                     + "(A15 and later) saves more with a tiny loss of quality. "
                     + "Fast Depth Readback answers the small depth checks some games do every "
                     + "frame (Mario Kart 7's sun glare) with the previous frame's values instead "
                     + "of waiting for the GPU. "
                     + "All of these apply the next time a game starts.")
            }

            Section {
                Toggle("Use External Display", isOn: $settings.useExternalDisplay)
                Picker("External Display Shows", selection: $settings.secondaryDisplayLayout) {
                    ForEach(0...7, id: \.self) {
                        Text(SecondaryLayoutOption.title(for: $0)).tag($0)
                    }
                }
                .disabled(!settings.useExternalDisplay)
            } header: {
                Text("External Display")
            } footer: {
                Text("With a TV or AirPlay display connected, the default shows the top screen on "
                     + "it and this device the bottom screen with the controls. The other choices "
                     + "give the display the screen layout you pick while this device keeps its "
                     + "own layout. Takes effect when a game starts. "
                     + "Running inside another app (such as LiveContainer) may stop iOS from "
                     + "offering the display to Azahar.")
            }
    }

    @ViewBuilder private var enhancementSections: some View {
            Section {
                Toggle("Custom Textures", isOn: $settings.customTextures)
                Toggle("Preload Custom Textures", isOn: $settings.preloadTextures)
                    .disabled(!settings.customTextures)
                Toggle("Load Custom Textures in the Background", isOn: $settings.asyncCustomTextures)
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
                if settings.stereoMode == .off {
                    Picker("Eye Shown", selection: $settings.monoEye) {
                        Text("Left").tag(0)
                        Text("Right").tag(1)
                    }
                }
                if settings.stereoMode == .anaglyph {
                    Picker("Anaglyph Colors", selection: $settings.anaglyphMode) {
                        Text("Dubois").tag(0)
                        Text("Gray").tag(1)
                        Text("Half Color").tag(2)
                        Text("Color").tag(3)
                    }
                }
                if settings.stereoMode == .cardboard {
                    Stepper("Cardboard Screen Size: \(settings.cardboardSize)%",
                            value: $settings.cardboardSize, in: 30...100, step: 5)
                    Stepper("Cardboard Horizontal Shift: \(settings.cardboardXShift)",
                            value: $settings.cardboardXShift, in: -100...100, step: 5)
                    Stepper("Cardboard Vertical Shift: \(settings.cardboardYShift)",
                            value: $settings.cardboardYShift, in: -100...100, step: 5)
                }
            } header: {
                Text("3D")
            } footer: {
                Text("Anaglyph needs red/cyan glasses. Interlaced shows the eyes on alternate rows "
                     + "of the screen. Side by Side and Cardboard VR show one picture per eye, for "
                     + "a headset or glasses holder (landscape). These modes don't use MetalFX.")
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
    }

    @ViewBuilder private var shaderSections: some View {
            Section {
                Picker("Effect", selection: $settings.postEffect) {
                    Text("None").tag(0)
                    Text("Sharpen").tag(1)
                    Text("LCD Grid").tag(2)
                    Text("Scanlines").tag(3)
                }
                Picker("Custom Shader", selection: $settings.postShader) {
                    Text("None").tag("")
                    ForEach(postShaders, id: \.self) { Text($0).tag($0) }
                }
                Button("Show Shaders Folder in Files") {
                    _ = PostShaders.availableNames()
                    FileLocations.showInFiles(FileLocations.postShadersDirectory)
                }
            } header: {
                Text("Post-Processing")
            } footer: {
                Text("An effect is applied to the finished screens. A custom shader replaces it: "
                     + "put a .metal file with a post_effect function in Files › Azahar › shaders "
                     + "› post (Example.metal shows how). A shader that does not compile is "
                     + "ignored, the log tells why. Applies when a game starts.")
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
                Toggle("Hold Frame While Shaders Build", isOn: $settings.holdFramesForShaders)
                    .disabled(!settings.asyncShaders)
                Picker("Wait for Shaders", selection: $settings.shaderWaitMs) {
                    Text("Never").tag(0)
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) ms").tag($0) }
                }
                .disabled(!settings.asyncShaders)
                Toggle("Disk Shader Cache", isOn: $settings.diskShaderCache)
                Button("Clear Shader Cache", role: .destructive) {
                    clearedShaderCache = FileLocations.clearShaderCache()
                }
            } header: {
                Text("Shaders")
            } footer: {
                Text("Async Shader Compilation builds new shaders in the background instead of "
                     + "pausing the game, an object may be missing for a moment instead. Hold "
                     + "Frame keeps showing the previous frame (up to three in a row) while a "
                     + "shader is still building, so nothing flickers; the picture repeats "
                     + "for a moment instead. Wait for Shaders lets a draw wait a few milliseconds "
                     + "for its shader first (at most four times that per frame), which avoids "
                     + "most skipped draws for a tiny hitch. Only frames with a hole in the "
                     + "screen-sized picture are held. The disk "
                     + "shader cache remembers the shaders of each game and builds them while it "
                     + "boots, so they don't need to be built again during play.")
            }
            .alert("Shader Cache Cleared", isPresented: $clearedShaderCache) {
                Button("OK", role: .cancel) {}
            }
    }

    /// Built in steps: one long concatenation with a condition in it is too much for the type
    /// checker.
    private static var performanceFooter: String {
        var text: String = "Frame Generation makes the frames between the real ones with Apple's "
        text += "frame interpolation, so a 30 FPS game looks like 60. Games that already run "
        text += "at 60 FPS are left alone: making a frame takes longer than a 60 FPS frame lasts. "
        if !FrameGenerator.isSupported {
            text += "Not available on this device or iOS version. "
        }
        text += "It adds about half a frame of delay, can smear text and the 3D depth, and uses "
        text += "more GPU and battery. It turns on Frame Presentation Skip. Faster Frame "
        text += "Generation makes the in-between frames at 3/8 of the screen size instead of half: "
        text += "less work and heat, slightly softer in-between frames. Top Screen Only leaves "
        text += "the bottom screen at the game's own frame rate, which halves the work in most "
        text += "layouts. Display-Driven Pacing (iOS 17 or later, experimental) lets the display "
        text += "pick up each frame at its own refresh instead of timing the frames in advance, "
        text += "which should keep them even at 60 Hz too.\n\n"
        text += "Frame Presentation Skip does not present a frame the game did not draw again, so "
        text += "a 30 FPS game shows 30 frames per second instead of every frame twice at 60. "
        text += "The emulation speed and the audio stay the same. Meant for frame generation and "
        text += "interpolation tools that need the real frame rate."
        return text
    }

    @ViewBuilder private var performanceSections: some View {
            Section {
                Toggle("Frame Presentation Skip", isOn: $settings.skipDuplicateFrames)
                Toggle("Frame Generation (Experimental)", isOn: Binding(
                    get: { settings.frameGeneration > 0 },
                    set: { settings.frameGeneration = $0 ? 1 : 0 }))
                Toggle("Faster Frame Generation", isOn: $settings.frameGenerationFast)
                    .disabled(settings.frameGeneration == 0)
                Toggle("Top Screen Only", isOn: $settings.frameGenerationTopOnly)
                    .disabled(settings.frameGeneration == 0)
                Toggle("Display-Driven Pacing", isOn: $settings.frameGenerationDisplayPaced)
                    .disabled(settings.frameGeneration == 0)
                .disabled(!FrameGenerator.isSupported)
                Toggle("Show Performance Overlay", isOn: $settings.showPerformanceOverlay)
            } header: {
                Text("Performance")
            } footer: {
                Text(verbatim: Self.performanceFooter)
            }
    }

    var body: some View {
        Form {
            rendererSections
            enhancementSections
            shaderSections
            performanceSections
        }
        .navigationTitle("Graphics")
    }
}

struct LayoutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var savingPreset = false
    @State private var presetName = ""

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
                Toggle("Integer Scaling", isOn: $settings.integerScaling)
                Picker("Aspect Ratio", selection: $settings.aspectRatio) {
                    Text("Default").tag(0)
                    Text("16:9").tag(1)
                    Text("4:3").tag(2)
                    Text("21:9").tag(3)
                    Text("16:10").tag(4)
                    Text("Stretch to Fit").tag(5)
                }
                Toggle("Stretch Top Screen", isOn: $settings.topStretch)
                Toggle("Stretch Bottom Screen", isOn: $settings.bottomStretch)
                if settings.topStretch {
                    Stepper("Top Screen Side Padding: \(settings.topPaddingH)",
                            value: $settings.topPaddingH, in: 0...400, step: 10)
                    Stepper("Top Screen Top/Bottom Padding: \(settings.topPaddingV)",
                            value: $settings.topPaddingV, in: 0...400, step: 10)
                }
                if settings.bottomStretch {
                    Stepper("Bottom Screen Side Padding: \(settings.bottomPaddingH)",
                            value: $settings.bottomPaddingH, in: 0...400, step: 10)
                    Stepper("Bottom Screen Top/Bottom Padding: \(settings.bottomPaddingV)",
                            value: $settings.bottomPaddingV, in: 0...400, step: 10)
                }
            } header: {
                Text("Shape")
            } footer: {
                Text("Aspect Ratio changes the shape the screens are drawn in. Stretching fills the "
                     + "window with a screen apart from the padding, in pixels. Applies to the "
                     + "layouts that do not place the screens by hand.")
            }
            Section {
                ForEach(settings.layoutPresets) { preset in
                    Button {
                        settings.applyLayoutPreset(preset)
                    } label: {
                        Text(preset.name).foregroundStyle(.primary)
                    }
                }
                .onDelete { settings.layoutPresets.remove(atOffsets: $0) }
                Button("Save Current Layout…") {
                    presetName = ""
                    savingPreset = true
                }
            } header: {
                Text("Saved Layouts")
            } footer: {
                Text("Tap a saved layout to use it, swipe to delete one. In a game, Next Screen "
                     + "Layout in the menu (or a controller shortcut) cycles through them, and "
                     + "Save Screen Layout saves what you set up with Edit Screen Layout.")
            }
            Section {
                Toggle("Respect Notch", isOn: $settings.respectNotch)
            } footer: {
                Text("Keeps the screens clear of the notch, the Dynamic Island and the rounded "
                     + "corners. Turn it off to draw the game edge to edge.")
            }
        }
        .navigationTitle("Layout")
        .alert("Save Layout", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { settings.saveLayoutPreset(named: presetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current screen layout. A layout with the same name is replaced.")
        }
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
                Picker("Audio Emulation", selection: $settings.audioEmulation) {
                    Text("HLE (Fast)").tag(0)
                    Text("LLE (Accurate)").tag(1)
                    Text("LLE Multithreaded").tag(2)
                }
                Toggle("Realtime Audio", isOn: $settings.realtimeAudio)
                Toggle("Use Microphone", isOn: $settings.useMicrophone)
            } footer: {
                Text("Audio stretching reduces stuttering when the emulation runs below full speed. "
                     + "HLE is the fast built-in audio. LLE runs the console's own audio "
                     + "processor, which is more accurate for games with audio glitches but "
                     + "slower (the multithreaded form runs it on its own thread) and needs the "
                     + "console's system files. Realtime Audio keeps the sound at its normal speed while a game runs "
                     + "slower than full speed, where it would slow down with the game; it can "
                     + "drift out of step with the picture in games that sync to it. Use "
                     + "Microphone lets games listen to the microphone of this device (it asks "
                     + "for permission when a game starts). Without it games hear static noise. "
                     + "Applies when a game starts.")
            }
        }
        .navigationTitle("Audio")
    }
}

struct SystemSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var storageName = CustomStorage.currentURL?.lastPathComponent

    var body: some View {
        Form {
            Section {
                NavigationLink("Console Profile") { ConsoleProfileView() }
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
                Toggle("Fixed Clock", isOn: $settings.fixedClock)
                if settings.fixedClock {
                    DatePicker("Console Time", selection: Binding(
                        get: { Date(timeIntervalSince1970: settings.fixedTime) },
                        set: { settings.fixedTime = $0.timeIntervalSince1970.rounded() }))
                }
                Toggle("Fixed Battery", isOn: $settings.fixedBattery)
                if settings.fixedBattery {
                    Stepper("Battery Level: \(settings.batteryLevel) of 4",
                            value: $settings.batteryLevel, in: 0...4)
                    Toggle("Charging", isOn: $settings.batteryCharging)
                }
                Stepper("Steps per Hour: \(settings.stepsPerHour)",
                        value: $settings.stepsPerHour, in: 0...20000, step: 100)
                Toggle("Region-Free Patch", isOn: $settings.regionFreePatch)
            } header: {
                Text("Console")
            } footer: {
                Text("A fixed clock starts every game at the time above (useful for games that "
                     + "depend on the date). Without a fixed battery the console reports this "
                     + "device's battery. Steps per Hour feeds games that count steps (the "
                     + "Play Coins). The region-free patch lets a game run on a console of "
                     + "another region.")
            }

            Section {
                Toggle("Deterministic Async Operations", isOn: $settings.deterministicAsync)
                Toggle("Simulate Headphones Plugged In", isOn: $settings.simulateHeadphones)
            } header: {
                Text("Compatibility")
            } footer: {
                Text("Deterministic Async Operations runs file and install operations that "
                     + "normally finish in the background at a fixed time and order, which helps "
                     + "netplay and movies stay in sync and can fix games that break on the "
                     + "timing. Simulate Headphones makes the console report headphones plugged "
                     + "in, which some games use to pick their audio mix.")
            }

            Section {
                Toggle("Built-in Game Hacks", isOn: $settings.gameHacksEnabled)
            } header: {
                Text("Game Hacks")
            } footer: {
                Text("The core knows games that need a workaround (accurate shader math for Ocarina "
                     + "of Time 3D, no right-eye skipping for the Luigi's Mansion games) and "
                     + "applies it by itself. Turn this off to run every game without them. A "
                     + "single game can decide each workaround for itself in its Game Settings "
                     + "under Game Hacks.")
            }

            Section {
                Toggle("LLE Applets", isOn: $settings.lleApplets)
                Toggle("Plugin Loader (3GX)", isOn: $settings.pluginLoader)
                Button("Show Plugins Folder in Files") {
                    try? FileManager.default.createDirectory(
                        at: FileLocations.pluginsDirectory, withIntermediateDirectories: true)
                    FileLocations.showInFiles(FileLocations.pluginsDirectory)
                }
            } header: {
                Text("Plugins")
            } footer: {
                Text("LLE Applets runs the console's own system applets (the Mii maker and the "
                     + "like) instead of the built-in ones; it needs the system files of a real "
                     + "console. Loads Luma-style 3GX plugins for games. Put a plugin in the folder of the "
                     + "game's title ID (Files › Azahar › sdmc › luma › plugins › 0004000000XXXXXX "
                     + "› plugin.3gx) or name it default.3gx in plugins. Applies when a game "
                     + "starts.")
            }

            Section {
                Toggle("Nintendo Network Support", isOn: $settings.onlineModules)
                NavigationLink("Online Play Guide") { OnlinePlayGuideView() }
            } header: {
                Text("Online Play")
            } footer: {
                Text("Runs the console's own online system modules (network, certificates, "
                     + "friends) instead of the built-in ones, which online games need. It needs "
                     + "the system files of a real console and a replacement for Nintendo's "
                     + "servers. See the guide. Applies when a game starts.")
            }

            Section {
                Toggle("Virtual SD Card", isOn: $settings.useVirtualSD)
                Toggle("Compress Installed CIAs", isOn: $settings.compressCIAInstalls)
                LabeledContent("Storage Folder", value: storageName ?? "Azahar folder")
                Button("Choose Storage Folder…") {
                    CustomStorage.choose { url in
                        if let url { storageName = url.lastPathComponent }
                    }
                }
                if storageName != nil {
                    Button("Use the Azahar Folder", role: .destructive) {
                        CustomStorage.reset()
                        storageName = nil
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("A chosen folder holds the console's nand and SD card (as the folders nand "
                     + "and sdmc inside it) instead of Files › Azahar. Existing data is not moved. "
                     + "Apps that run inside another app (LiveContainer) may not be allowed to "
                     + "use a folder outside their own; the Azahar folder is used then. Applies "
                     + "when a game starts.")
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

/// What online play needs and how to set it up.
struct OnlinePlayGuideView: View {
    var body: some View {
        List {
            Section("What you need") {
                Text("1. The system files of your own 3DS, installed with the Artic Setup Tool "
                     + "(Games › the antenna button › Setup Tool). They include the certificates "
                     + "and the online system modules.")
                Text("2. Nintendo's servers are gone. Games connect to a replacement, such as "
                     + "Pretendo Network, which needs its own patch for the game and for the "
                     + "console's account. Follow the instructions of the service you use.")
                Text("3. Turn on Nintendo Network Support in Settings › System, and the plugin "
                     + "loader if the service's patch is a 3GX plugin.")
            }
            Section("Good to know") {
                Text("This runs the real online modules, so it only works with a complete setup "
                     + "from your console. It is slower to start a game, and it has not been "
                     + "tested with every service.")
                Text("Local wireless play with others on the same network is separate: use "
                     + "Multiplayer in the game menu.")
            }
        }
        .navigationTitle("Online Play")
    }
}

/// The user name, birthday, language, country, sound mode and Play Coins of the emulated console.
struct ConsoleProfileView: View {
    @State private var username = ""
    @State private var birthMonth = 1
    @State private var birthDay = 1
    @State private var language = 1
    @State private var country = 49
    @State private var soundMode = 1
    @State private var playCoins = 0
    @State private var loaded = false
    @State private var saved = false
    @State private var failed = false

    private static let languages = [
        "Japanese", "English", "French", "German", "Italian", "Spanish", "Chinese (Simplified)",
        "Korean", "Dutch", "Portuguese", "Russian", "Chinese (Traditional)",
    ]
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]

    var body: some View {
        Form {
            Section {
                TextField("User Name", text: Binding(
                    get: { username },
                    set: { username = String($0.prefix(10)) }))
                Picker("Birth Month", selection: $birthMonth) {
                    ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) }
                }
                Picker("Birth Day", selection: $birthDay) {
                    ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("You")
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(0..<Self.languages.count, id: \.self) {
                        Text(Self.languages[$0]).tag($0)
                    }
                }
                Picker("Country", selection: $country) {
                    ForEach(CountryNames.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Sound", selection: $soundMode) {
                    Text("Mono").tag(0)
                    Text("Stereo").tag(1)
                    Text("Surround").tag(2)
                }
                Stepper("Play Coins: \(playCoins)", value: $playCoins, in: 0...300)
            } header: {
                Text("Console")
            } footer: {
                Text("These are the settings of the emulated console, which games read. A country "
                     + "that does not belong to the console's region can stop some games from "
                     + "starting.")
            }

            Section {
                Button("Save") {
                    let profile = AZConsoleProfile()
                    profile.username = username
                    profile.birthMonth = birthMonth
                    profile.birthDay = birthDay
                    profile.language = language
                    profile.country = country
                    profile.soundMode = soundMode
                    profile.playCoins = playCoins
                    if AZEmulator.writeConsoleProfile(profile) {
                        saved = true
                    } else {
                        failed = true
                    }
                }
            }
        }
        .navigationTitle("Console Profile")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let profile = AZEmulator.readConsoleProfile()
            username = profile.username
            birthMonth = max(1, profile.birthMonth)
            birthDay = max(1, profile.birthDay)
            language = profile.language
            country = profile.country
            soundMode = profile.soundMode
            playCoins = profile.playCoins
        }
        .alert("Saved", isPresented: $saved) { Button("OK", role: .cancel) {} }
        .alert("Not Saved", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The profile can only be changed while no game runs.")
        }
    }
}
