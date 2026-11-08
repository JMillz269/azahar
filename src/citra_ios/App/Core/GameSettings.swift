// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import Foundation

/// Settings a game can override. A nil value means the game uses the global setting.
struct GameOverrides: Codable, Equatable {
    var resolutionFactor: Int?
    var textureFilter: Int?
    var upscaling: Int?
    var anisotropy: Int?
    var fastShaderMath: Bool?
    var fastLighting: Bool?
    var fastColor: Bool?
    var realtimeAudio: Bool?
    var fastDepthReadback: Bool?
    var hiddenSurfaceRemoval: Bool?
    var textureCompression: Int?
    var hardwareShaders: Bool?
    var cpuClockPercentage: Int?
    var stereoMode: Int?
    var region: Int?
    var isNew3DS: Bool?
    var aspectRatio: Int?
    var textureSampling: Int?
    var monoEye: Int?
    var audioEmulation: Int?
    var lleApplets: Bool?
    var pluginLoader: Bool?
    var onlineModules: Bool?
    var regionFreePatch: Bool?
    var postEffect: Int?
    var fastForwardSpeed: Int?
    /// 0 runs without a speed limit, other values limit the speed to that percentage.
    var speedLimit: Int?

    var isEmpty: Bool { self == GameOverrides() }

    /// Replaces the fields of the configuration the game overrides.
    func apply(to config: AZConfiguration) {
        if let resolutionFactor { config.resolutionFactor = resolutionFactor }
        if let textureFilter { config.textureFilter = textureFilter }
        if let upscaling { config.upscaling = upscaling }
        if let anisotropy { config.anisotropy = anisotropy }
        if let fastShaderMath { config.fastShaderMath = fastShaderMath }
        if let fastLighting { config.fastLighting = fastLighting }
        if let fastColor { config.fastColor = fastColor }
        if let realtimeAudio { config.realtimeAudio = realtimeAudio }
        if let fastDepthReadback { config.fastDepthReadback = fastDepthReadback }
        if let hiddenSurfaceRemoval { config.hiddenSurfaceRemoval = hiddenSurfaceRemoval }
        if let textureCompression { config.textureCompression = textureCompression }
        if let hardwareShaders { config.useHardwareShaders = hardwareShaders }
        if let cpuClockPercentage { config.cpuClockPercentage = cpuClockPercentage }
        if let stereoMode { config.stereoMode = stereoMode }
        if let region { config.region = region }
        if let isNew3DS { config.isNew3DS = isNew3DS }
        if let aspectRatio { config.aspectRatio = aspectRatio }
        if let textureSampling { config.textureSampling = textureSampling }
        if let monoEye { config.monoEye = monoEye }
        if let audioEmulation { config.audioEmulation = audioEmulation }
        if let lleApplets { config.lleApplets = lleApplets }
        if let pluginLoader { config.pluginLoader = pluginLoader }
        if let onlineModules { config.onlineModules = onlineModules }
        if let regionFreePatch { config.regionFreePatch = regionFreePatch }
        if let postEffect { config.postEffect = postEffect }
        if let fastForwardSpeed { config.fastForwardSpeed = fastForwardSpeed }
        if let speedLimit {
            config.useFrameLimit = speedLimit != 0
            if speedLimit != 0 { config.frameLimit = speedLimit }
        }
    }
}

/// Keeps the overrides of every game, by title ID, in UserDefaults.
final class GameOverridesStore: ObservableObject {
    static let shared = GameOverridesStore()

    private let defaults = UserDefaults.standard
    private let key = "gameOverrides"
    private var all: [String: GameOverrides]

    private init() {
        if let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: GameOverrides].self, from: data)
        {
            all = decoded
        } else {
            all = [:]
        }
    }

    func overrides(for game: Game) -> GameOverrides {
        all[game.programIDString] ?? GameOverrides()
    }

    func set(_ overrides: GameOverrides, for game: Game) {
        objectWillChange.send()
        if overrides.isEmpty {
            all[game.programIDString] = nil
        } else {
            all[game.programIDString] = overrides
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    func hasOverrides(_ game: Game) -> Bool {
        all[game.programIDString] != nil
    }
}
