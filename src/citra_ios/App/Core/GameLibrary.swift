// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import Foundation
import UIKit

struct Game: Identifiable, Hashable {
    let url: URL
    let title: String
    let publisher: String
    let regions: String
    let fileType: String
    let programID: UInt64
    let isEncrypted: Bool
    let icon: UIImage?

    var id: String { url.path }

    var programIDString: String {
        String(format: "%016llX", programID)
    }

    static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Scans the ROMs directory and keeps the list of games.
@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published private(set) var isScanning = false
    @Published var importError: String?

    init() {
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let directory = FileLocations.romsDirectory
        Task.detached(priority: .userInitiated) {
            let games = GameLibrary.scan(directory: directory)
            await MainActor.run {
                self.games = games
                self.isScanning = false
            }
        }
    }

    /// Copies (or moves, for files already inside our sandbox inbox) the provided files into the
    /// ROMs directory.
    func importFiles(_ urls: [URL]) {
        let destination = FileLocations.romsDirectory
        var failures: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let target = destination.appendingPathComponent(url.lastPathComponent)
            guard target.standardizedFileURL != url.standardizedFileURL else { continue }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
        }
        refresh()
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.url)
        refresh()
    }

    nonisolated private static func scan(directory: URL) -> [Game] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var games: [Game] = []
        for case let url as URL in enumerator {
            guard FileLocations.bootableExtensions.contains(url.pathExtension.lowercased()),
                let info = AZGameInfo(path: url.path)
            else { continue }
            games.append(
                Game(
                    url: url, title: info.title, publisher: info.publisher, regions: info.regions,
                    fileType: info.fileType, programID: info.programID,
                    isEncrypted: info.isEncrypted, icon: makeIcon(info.iconRGBA)))
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func makeIcon(_ data: Data?) -> UIImage? {
        guard let data, data.count == 48 * 48 * 4,
            let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 48 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
