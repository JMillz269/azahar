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
    /// The button opening the emulation menu. It is placed like a control but drawn and handled
    /// by EmulationView, so it stays available while the controller is hidden.
    case menuButton
    /// Fast forwards while held.
    case turboButton

    var id: String { rawValue }

    /// The controls of the on-screen controller itself, without the menu button.
    static let controllerControls = allCases.filter { $0 != .menuButton }

    var title: String {
        switch self {
        case .shoulderLeft: return "L / ZL"
        case .shoulderRight: return "R / ZR"
        case .circlePad: return "Circle Pad"
        case .dpad: return "D-Pad"
        case .faceButtons: return "A / B / X / Y"
        case .cStick: return "C-Stick"
        case .systemButtons: return "Select / Home / Start"
        case .menuButton: return "Menu Button"
        case .turboButton: return "Turbo Button"
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

/// The user's controller layouts. Portrait and landscape are stored separately because the screen
/// is very different, and positions are fractions of the screen so they hold up on other devices.
///
/// There is one global layout. A game can have a layout of its own (see `setUsesGameLayout`); the
/// placements the views read always belong to the layout of the game that is running, or to the
/// global one when no game runs.
@MainActor
final class ControllerLayoutStore: ObservableObject {
    @Published private(set) var portraitPlacements: [String: ControlPlacement] = [:]
    @Published private(set) var landscapePlacements: [String: ControlPlacement] = [:]
    /// The game whose layout is active, nil for the global one.
    @Published private(set) var activeGameID: String?
    @Published private(set) var usesGameLayout = false

    private struct Stored: Codable {
        var portrait: [String: ControlPlacement] = [:]
        var landscape: [String: ControlPlacement] = [:]
    }

    private static let defaultsKey = "controllerLayout.v1"
    private static let gamesKey = "controllerLayout.games.v1"

    private var global = Stored()
    private var games: [String: Stored] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            global = stored
        }
        if let data = defaults.data(forKey: Self.gamesKey),
            let stored = try? JSONDecoder().decode([String: Stored].self, from: data)
        {
            games = stored
        }
        load()
    }

    /// Makes the layout of a game (or the global one for nil) the one the views use.
    func activate(gameID: String?) {
        activeGameID = gameID
        load()
    }

    /// Whether the active game could have a layout of its own.
    var hasActiveGame: Bool { activeGameID != nil }

    /// Gives the active game a layout of its own, starting from the global one, or takes it back
    /// to the global layout.
    func setUsesGameLayout(_ enabled: Bool) {
        guard let id = activeGameID else { return }
        if enabled {
            games[id] = global
        } else {
            games[id] = nil
        }
        persist()
        load()
    }

    private func load() {
        let stored: Stored
        if let id = activeGameID, let own = games[id] {
            stored = own
            usesGameLayout = true
        } else {
            stored = global
            usesGameLayout = false
        }
        portraitPlacements = stored.portrait
        landscapePlacements = stored.landscape
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

    /// Resets the global layout and the layouts of all games, both orientations.
    func resetEverything() {
        global = Stored()
        games = [:]
        persist()
        load()
    }

    /// Saves the placements in use into the layout they belong to.
    func commit() {
        let stored = Stored(portrait: portraitPlacements, landscape: landscapePlacements)
        if usesGameLayout, let id = activeGameID {
            games[id] = stored
        } else {
            global = stored
        }
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(global) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        if let data = try? JSONEncoder().encode(games) {
            defaults.set(data, forKey: Self.gamesKey)
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
