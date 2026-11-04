// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Combine
import Foundation

/// A part of the on-screen controller that can be moved and resized on its own.
enum ControlID: String, CaseIterable, Identifiable {
    case shoulderLeft
    case shoulderRight
    case circlePad
    case dpad
    case faceButtons
    case cStick
    case systemButtons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shoulderLeft: return "L / ZL"
        case .shoulderRight: return "R / ZR"
        case .circlePad: return "Circle Pad"
        case .dpad: return "D-Pad"
        case .faceButtons: return "A / B / X / Y"
        case .cStick: return "C-Stick"
        case .systemButtons: return "Select / Home / Start"
        }
    }
}

/// Where a control sits compared to its default position, and how big it is.
struct ControlPlacement: Codable, Equatable {
    /// Offset from the default position as a fraction of the screen width.
    var dx: Double = 0
    /// Offset from the default position as a fraction of the screen height.
    var dy: Double = 0
    /// Size relative to the default size.
    var scale: Double = 1

    static let scaleRange: ClosedRange<Double> = 0.5...2.0
}

/// The user's controller layout. Portrait and landscape are stored separately because the screen
/// is very different, and positions are fractions of the screen so they hold up on other devices.
@MainActor
final class ControllerLayoutStore: ObservableObject {
    @Published private(set) var portraitPlacements: [String: ControlPlacement]
    @Published private(set) var landscapePlacements: [String: ControlPlacement]

    private struct Stored: Codable {
        var portrait: [String: ControlPlacement]
        var landscape: [String: ControlPlacement]
    }

    private static let defaultsKey = "controllerLayout.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            portraitPlacements = stored.portrait
            landscapePlacements = stored.landscape
        } else {
            portraitPlacements = [:]
            landscapePlacements = [:]
        }
    }

    func placement(for id: ControlID, portrait: Bool) -> ControlPlacement {
        let placements = portrait ? portraitPlacements : landscapePlacements
        return placements[id.rawValue] ?? ControlPlacement()
    }

    /// Changes a placement. Call `commit()` when the change is finished to save it.
    func update(_ id: ControlID, portrait: Bool, _ change: (inout ControlPlacement) -> Void) {
        var placement = self.placement(for: id, portrait: portrait)
        change(&placement)
        placement.scale = min(
            max(placement.scale, ControlPlacement.scaleRange.lowerBound),
            ControlPlacement.scaleRange.upperBound)
        store(placement, for: id, portrait: portrait)
    }

    func reset(_ id: ControlID, portrait: Bool) {
        store(ControlPlacement(), for: id, portrait: portrait)
        commit()
    }

    /// Resets every control of one orientation.
    func resetAll(portrait: Bool) {
        if portrait {
            portraitPlacements = [:]
        } else {
            landscapePlacements = [:]
        }
        commit()
    }

    /// Resets every control of both orientations.
    func resetEverything() {
        portraitPlacements = [:]
        landscapePlacements = [:]
        commit()
    }

    func commit() {
        let stored = Stored(portrait: portraitPlacements, landscape: landscapePlacements)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func store(_ placement: ControlPlacement, for id: ControlID, portrait: Bool) {
        let value: ControlPlacement? = placement == ControlPlacement() ? nil : placement
        if portrait {
            portraitPlacements[id.rawValue] = value
        } else {
            landscapePlacements[id.rawValue] = value
        }
    }
}
