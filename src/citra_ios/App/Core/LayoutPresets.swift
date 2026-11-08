// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Foundation

/// A saved arrangement of the screens: the layout options of both orientations and the positions
/// of the custom layout.
struct LayoutPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: Int
    var portraitLayout: Int
    var swapScreens: Bool
    var uprightScreens: Bool
    var screenGap: Int
    var largeScreenProportion: Double
    var smallScreenPlacement: Int
    var customLandscape: [Double]
    var customPortrait: [Double]
    var aspectRatio: Int
}

extension AppSettings {
    /// A preset holding the screen layout as it is now.
    func currentLayoutPreset(named name: String) -> LayoutPreset {
        LayoutPreset(
            name: name, layout: layout.rawValue, portraitLayout: portraitLayout.rawValue,
            swapScreens: swapScreens, uprightScreens: uprightScreens, screenGap: screenGap,
            largeScreenProportion: largeScreenProportion,
            smallScreenPlacement: smallScreenPlacement.rawValue,
            customLandscape: customLayoutLandscape, customPortrait: customLayoutPortrait,
            aspectRatio: aspectRatio)
    }

    /// Saves the current layout under a name (a preset with that name is replaced).
    func saveLayoutPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var preset = currentLayoutPreset(named: trimmed)
        if let index = layoutPresets.firstIndex(where: { $0.name == trimmed }) {
            preset.id = layoutPresets[index].id
            layoutPresets[index] = preset
        } else {
            layoutPresets.append(preset)
        }
    }

    func applyLayoutPreset(_ preset: LayoutPreset) {
        layout = ScreenLayout(rawValue: preset.layout) ?? .standard
        portraitLayout = PortraitScreenLayout(rawValue: preset.portraitLayout) ?? .topFullWidth
        swapScreens = preset.swapScreens
        uprightScreens = preset.uprightScreens
        screenGap = preset.screenGap
        largeScreenProportion = preset.largeScreenProportion
        smallScreenPlacement = SmallScreenPlacement(rawValue: preset.smallScreenPlacement)
            ?? .topRight
        customLayoutLandscape = preset.customLandscape
        customLayoutPortrait = preset.customPortrait
        aspectRatio = preset.aspectRatio
    }

    /// Applies the next preset after the one applied last and returns it, nil when there are
    /// none.
    func cycleLayout() -> LayoutPreset? {
        guard !layoutPresets.isEmpty else { return nil }
        let next = (lastLayoutPresetIndex + 1) % layoutPresets.count
        lastLayoutPresetIndex = next
        let preset = layoutPresets[next]
        applyLayoutPreset(preset)
        return preset
    }
}
