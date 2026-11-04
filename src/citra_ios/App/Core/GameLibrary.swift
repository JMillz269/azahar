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
    @Published private(set) var isImporting = false
    @Published var importError: String?
    /// Set when a refresh was requested during a scan, so the files added meanwhile are not missed.
    private var needsRescan = false

    init() {
        refresh()
    }

    func refresh() {
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let directory = FileLocations.romsDirectory
        Task.detached(priority: .userInitiated) {
            let games = GameLibrary.scan(directory: directory)
            await MainActor.run {
                self.games = games
                self.isScanning = false
                if self.needsRescan {
                    self.needsRescan = false
                    self.refresh()
                }
            }
        }
    }

    /// Imports the provided files into the ROMs directory. Files that live in this app's temporary
    /// directory (the copies made by the document picker) are moved, everything else is copied.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let destination = FileLocations.romsDirectory
        Task.detached(priority: .userInitiated) {
            let failures = GameLibrary.importItems(urls, into: destination)
            await MainActor.run {
                self.isImporting = false
                if !failures.isEmpty {
                    self.importError = failures.joined(separator: "\n")
                }
                self.refresh()
            }
        }
    }

    /// Returns a description of every file that could not be imported.
    nonisolated private static func importItems(_ urls: [URL], into destination: URL) -> [String] {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return ["Could not create the games folder: \(error.localizedDescription)"]
        }

        var failures: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            guard FileLocations.bootableExtensions.contains(url.pathExtension.lowercased()) else {
                failures.append("\(name): unsupported file type. Supported types: "
                    + FileLocations.bootableExtensions.sorted().joined(separator: ", "))
                continue
            }

            // Files provided by other apps may need security scoped access; the copies made by
            // the document picker do not, in which case this simply returns false.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let target = destination.appendingPathComponent(name)
            guard target.standardizedFileURL != url.standardizedFileURL else { continue }
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                if isInTemporaryDirectory(url) {
                    do {
                        try fileManager.moveItem(at: url, to: target)
                        continue
                    } catch {
                        // Fall through to a plain copy.
                    }
                }
                try fileManager.copyItem(at: url, to: target)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return failures
    }

    nonisolated private static func isInTemporaryDirectory(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(temporary.path + "/")
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
