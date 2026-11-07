// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import Foundation
import UIKit

/// Turns games into their compressed form (.zcci, .zcxi, .z3dsx, .zcia): smaller files the
/// emulator reads directly. The compressed files are written to the ROMs folder.
@MainActor
final class GameCompressor: ObservableObject {
    @Published private(set) var isRunning = false
    /// The file being compressed and how far it is (0 to 1).
    @Published private(set) var currentName: String?
    @Published private(set) var progress: Double = 0
    /// Position in the queue, for "2 of 5".
    @Published private(set) var position = 0
    @Published private(set) var total = 0
    /// What the last run did, for an alert.
    @Published var summary: String?

    /// Compresses the files one after the other. `deleteSources` removes a file once its
    /// compressed copy exists (only for files that were compressed successfully).
    func compress(_ urls: [URL], deleteSources: Bool, library: GameLibrary) {
        guard !isRunning, !urls.isEmpty else { return }
        isRunning = true
        total = urls.count
        position = 0
        let destination = FileLocations.romsDirectory
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        Task { @MainActor in
            var done = 0
            var saved: Int64 = 0
            var skipped: [String] = []
            var failed: [String] = []
            for url in urls {
                position += 1
                currentName = url.lastPathComponent
                progress = 0
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                let result: (AZCompressStatus, String?) = await withCheckedContinuation { continuation in
                    AZEmulator.compressGame(
                        atPath: url.path, toDirectory: destination.path,
                        progress: { [weak self] fraction in self?.progress = fraction },
                        completion: { status, output in continuation.resume(returning: (status, output)) })
                }

                switch result.0 {
                case .success:
                    done += 1
                    if let output = result.1 {
                        saved += GameCompressor.size(of: url) - GameCompressor.size(of: URL(fileURLWithPath: output))
                    }
                    if deleteSources {
                        try? FileManager.default.removeItem(at: url)
                    }
                case .alreadyCompressed:
                    skipped.append("\(url.lastPathComponent): already compressed")
                case .notSupported:
                    skipped.append("\(url.lastPathComponent): cannot be compressed (encrypted, "
                        + "bundled or not a supported file)")
                default:
                    failed.append(url.lastPathComponent)
                }
            }

            var lines: [String] = []
            if done > 0 {
                lines.append("Compressed \(done) \(done == 1 ? "file" : "files"), saving "
                    + ByteCountFormatter.string(fromByteCount: max(saved, 0), countStyle: .file)
                    + (deleteSources ? " (originals removed)." : "."))
            }
            lines += skipped
            lines += failed.map { "\($0): failed" }
            // The copies the document picker made are not needed any more.
            for url in urls where GameCompressor.isTemporary(url) {
                try? FileManager.default.removeItem(at: url)
            }
            summary = lines.joined(separator: "\n")
            currentName = nil
            isRunning = false
            library.refresh()
        }
    }

    nonisolated private static func isTemporary(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            .hasPrefix(temporary.path + "/")
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// The files of the ROMs folder that can be compressed (not compressed already).
    static func compressibleFilesInLibrary() -> [URL] {
        let compressible: Set<String> = ["3ds", "cci", "cxi", "3dsx", "cia"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: FileLocations.romsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { compressible.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
