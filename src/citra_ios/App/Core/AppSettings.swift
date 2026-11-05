// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import Combine
import Foundation

enum LibraryStyle: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Grid" }
}

enum ScreenLayout: Int, CaseIterable, Identifiable {
    case standard = 0
    case singleScreen = 1
    case largeScreen = 2
    case sideBySide = 3
    case hybrid = 5

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .standard: return "Default"
        case .singleScreen: return "Single Screen"
        case .largeScreen: return "Large Screen"
        case .sideBySide: return "Side by Side"
        case .hybrid: return "Hybrid"
        }
    }
}

enum PortraitScreenLayout: Int, CaseIterable, Identifiable {
    case topFullWidth = 0
    case original = 2

    var id: Int { rawValue }
    var title: String { self == .topFullWidth ? "Top Full Width" : "Original" }
}

enum ConsoleRegion: Int, CaseIterable, Identifiable {
    case auto = -1
    case japan = 0
    case usa = 1
    case europe = 2
    case australia = 3
    case china = 4
    case korea = 5
    case taiwan = 6

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto-select"
        case .japan: return "Japan"
        case .usa: return "USA"
        case .europe: return "Europe"
        case .australia: return "Australia"
        case .china: return "China"
        case .korea: return "Korea"
        case .taiwan: return "Taiwan"
        }
    }
}

enum UpscalingOption: Int, CaseIterable, Identifiable {
    case off = 0
    case spatial = 1

    var id: Int { rawValue }
    var title: String { self == .off ? "Off" : "MetalFX Spatial" }
}

enum TextureFilterOption: Int, CaseIterable, Identifiable {
    case none = 0
    case anime4k = 1
    case bicubic = 2
    case scaleForce = 3
    case xbrz = 4
    case mmpx = 5

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .anime4k: return "Anime4K"
        case .bicubic: return "Bicubic"
        case .scaleForce: return "ScaleForce"
        case .xbrz: return "xBRZ"
        case .mmpx: return "MMPX"
        }
    }
}

/// Persisted user settings. Values are stored in UserDefaults and converted to an AZConfiguration
/// when a game starts.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // App
    @Published var libraryStyle: LibraryStyle { didSet { save(libraryStyle.rawValue, "libraryStyle") } }
    @Published var showPerformanceOverlay: Bool { didSet { save(showPerformanceOverlay, "showPerformanceOverlay") } }
    @Published var showController: Bool { didSet { save(showController, "showController") } }
    @Published var controllerOpacity: Double { didSet { save(controllerOpacity, "controllerOpacity") } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, "hapticFeedback") } }
    @Published var useMotion: Bool { didSet { save(useMotion, "useMotion") } }

    // CPU
    @Published var cpuJIT: Bool { didSet { save(cpuJIT, "cpuJIT") } }
    @Published var cpuClockPercentage: Int { didSet { save(cpuClockPercentage, "cpuClockPercentage") } }

    // Graphics
    @Published var shaderJIT: Bool { didSet { save(shaderJIT, "shaderJIT") } }
    @Published var resolutionFactor: Int { didSet { save(resolutionFactor, "resolutionFactor") } }
    @Published var linearFiltering: Bool { didSet { save(linearFiltering, "linearFiltering") } }
    @Published var textureFilter: TextureFilterOption { didSet { save(textureFilter.rawValue, "textureFilter") } }
    @Published var skipDuplicateFrames: Bool { didSet { save(skipDuplicateFrames, "skipDuplicateFrames") } }
    @Published var upscaling: UpscalingOption { didSet { save(upscaling.rawValue, "upscaling") } }

    // Layout
    @Published var layout: ScreenLayout { didSet { save(layout.rawValue, "layout") } }
    @Published var portraitLayout: PortraitScreenLayout { didSet { save(portraitLayout.rawValue, "portraitLayout") } }
    @Published var swapScreens: Bool { didSet { save(swapScreens, "swapScreens") } }
    @Published var respectNotch: Bool { didSet { save(respectNotch, "respectNotch") } }

    // Audio
    @Published var audioStretching: Bool { didSet { save(audioStretching, "audioStretching") } }
    @Published var volume: Double { didSet { save(volume, "volume") } }

    // System
    @Published var isNew3DS: Bool { didSet { save(isNew3DS, "isNew3DS") } }
    @Published var region: ConsoleRegion { didSet { save(region.rawValue, "region") } }
    @Published var useFrameLimit: Bool { didSet { save(useFrameLimit, "useFrameLimit") } }
    @Published var frameLimit: Int { didSet { save(frameLimit, "frameLimit") } }

    init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }

        libraryStyle = LibraryStyle(rawValue: value("libraryStyle", LibraryStyle.grid.rawValue)) ?? .grid
        showPerformanceOverlay = value("showPerformanceOverlay", true)
        showController = value("showController", true)
        controllerOpacity = value("controllerOpacity", 0.7)
        hapticFeedback = value("hapticFeedback", true)
        useMotion = value("useMotion", true)

        cpuJIT = value("cpuJIT", true)
        cpuClockPercentage = value("cpuClockPercentage", 100)

        shaderJIT = value("shaderJIT", true)
        resolutionFactor = value("resolutionFactor", 2)
        linearFiltering = value("linearFiltering", true)
        textureFilter = TextureFilterOption(rawValue: value("textureFilter", 0)) ?? .none
        skipDuplicateFrames = value("skipDuplicateFrames", false)
        upscaling = UpscalingOption(rawValue: value("upscaling", 0)) ?? .off

        layout = ScreenLayout(rawValue: value("layout", ScreenLayout.standard.rawValue)) ?? .standard
        portraitLayout = PortraitScreenLayout(rawValue: value("portraitLayout", 0)) ?? .topFullWidth
        swapScreens = value("swapScreens", false)
        respectNotch = value("respectNotch", true)

        audioStretching = value("audioStretching", true)
        volume = value("volume", 1.0)

        isNew3DS = value("isNew3DS", true)
        region = ConsoleRegion(rawValue: value("region", -1)) ?? .auto
        useFrameLimit = value("useFrameLimit", true)
        frameLimit = value("frameLimit", 100)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// Builds the core configuration from the current settings.
    func makeConfiguration() -> AZConfiguration {
        let config = AZConfiguration.makeDefault()
        config.useCPUJIT = cpuJIT
        config.cpuClockPercentage = cpuClockPercentage
        config.useShaderJIT = shaderJIT
        config.resolutionFactor = resolutionFactor
        config.linearFiltering = linearFiltering
        config.textureFilter = textureFilter.rawValue
        config.skipDuplicateFrames = skipDuplicateFrames
        config.upscaling = upscaling.rawValue
        config.layoutOption = AZLayoutOption(rawValue: layout.rawValue) ?? .default
        config.portraitLayoutOption =
            AZPortraitLayoutOption(rawValue: portraitLayout.rawValue) ?? .topFullWidth
        config.swapScreens = swapScreens
        config.audioStretching = audioStretching
        config.volume = Float(volume)
        config.isNew3DS = isNew3DS
        config.region = region.rawValue
        config.useFrameLimit = useFrameLimit
        config.frameLimit = frameLimit
        return config
    }
}
