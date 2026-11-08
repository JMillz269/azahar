// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

/// What is remembered about each game: whether it is a favorite, how long it was played and when.
@MainActor
final class GameStatsStore: ObservableObject {
    static let shared = GameStatsStore()

    struct Entry: Codable {
        var favorite = false
        var playSeconds: Double = 0
        var lastPlayed: Date?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private static let key = "gameStats.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func entry(for game: Game) -> Entry {
        entries[game.programIDString] ?? Entry()
    }

    func isFavorite(_ game: Game) -> Bool {
        entry(for: game).favorite
    }

    func toggleFavorite(_ game: Game) {
        var entry = self.entry(for: game)
        entry.favorite.toggle()
        entries[game.programIDString] = entry
        save()
    }

    func recordPlay(of programID: UInt64, seconds: Double, at date: Date) {
        guard seconds >= 1 else { return }
        let key = String(format: "%016llX", programID)
        var entry = entries[key] ?? Entry()
        entry.playSeconds += seconds
        entry.lastPlayed = date
        entries[key] = entry
        save()
    }

    /// "3 h 20 min", "12 min" or "Never played".
    static func playTimeText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds >= 1 ? "Less than a minute" : "Never played" }
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        return hours > 0 ? "\(hours) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// How well a game runs, from the compatibility list of the project (bundled with the app).
enum CompatibilityList {
    struct Rating {
        let text: String
        let color: Color
    }

    private static let ratings: [Int: Rating] = [
        0: Rating(text: "Perfect", color: Color(red: 0.36, green: 0.58, blue: 0.93)),
        1: Rating(text: "Great", color: Color(red: 0.28, green: 0.83, blue: 0.36)),
        2: Rating(text: "Okay", color: Color(red: 0.58, green: 0.70, blue: 0.26)),
        3: Rating(text: "Bad", color: Color(red: 0.95, green: 0.84, blue: 0.14)),
        4: Rating(text: "Intro/Menu", color: Color.red),
        5: Rating(text: "Won't Boot", color: Color.gray),
    ]

    /// Title ID (16 hex digits, upper case) to the rating code.
    private static let codes: [String: Int] = {
        guard let url = Bundle.main.url(forResource: "compatibility_list", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var result: [String: Int] = [:]
        for entry in list {
            guard let code = entry["compatibility"] as? Int, code != 99,
                  let releases = entry["releases"] as? [[String: Any]]
            else { continue }
            for release in releases {
                if let id = release["id"] as? String {
                    result[id.uppercased()] = code
                }
            }
        }
        return result
    }()

    static func rating(of game: Game) -> Rating? {
        // The listed id is the title's, installed updates and DLC have other ids.
        guard let code = codes[game.programIDString.uppercased()] else { return nil }
        return ratings[code]
    }
}

/// A small colored dot with the rating of a game.
struct CompatibilityBadge: View {
    let game: Game

    var body: some View {
        if let rating = CompatibilityList.rating(of: game) {
            Circle()
                .fill(rating.color)
                .frame(width: 9, height: 9)
                .accessibilityLabel("Compatibility: \(rating.text)")
        }
    }
}
