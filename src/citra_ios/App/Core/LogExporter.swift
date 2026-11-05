// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Foundation
import SwiftUI
import UIKit

/// Builds a log small enough to share. The emulator log can grow to 100 MB when a game spams it,
/// which is too big to attach anywhere, so only the start (configuration, JIT status and the
/// first errors) and the end are kept, together with the last crash report.
enum LogExporter {
    /// Bytes kept from the start and from the end of the log.
    private static let headSize = 256 * 1024
    private static let tailSize = 2 * 1024 * 1024

    private static var logDirectory: URL {
        FileLocations.userDirectory.appendingPathComponent("log", isDirectory: true)
    }

    /// Writes the trimmed log to a temporary file and returns it, or nil if there is no log.
    static func makeShareableLog() -> URL? {
        let fileManager = FileManager.default
        var output = Data()

        if let report = try? String(
            contentsOf: logDirectory.appendingPathComponent("crash_report.txt"), encoding: .utf8),
            !report.isEmpty
        {
            output.append(Data("===== Last crash report =====\n\(report)\n\n".utf8))
        }

        let logURL = logDirectory.appendingPathComponent("azahar_log.txt")
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return output.isEmpty ? nil : write(output)
        }
        defer { try? handle.close() }

        let size = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
        output.append(Data("===== azahar_log.txt (\(size) bytes) =====\n".utf8))
        if size <= UInt64(headSize + tailSize) {
            if let data = try? handle.readToEnd() {
                output.append(data)
            }
        } else {
            if let head = try? handle.read(upToCount: headSize) {
                output.append(head)
            }
            let skipped = size - UInt64(headSize + tailSize)
            output.append(Data("\n\n... \(skipped) bytes left out ...\n\n".utf8))
            try? handle.seek(toOffset: size - UInt64(tailSize))
            if let tail = try? handle.readToEnd() {
                output.append(tail)
            }
        }
        return write(output)
    }

    private static func write(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("azahar_log.txt")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// The system share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifies a file to share so it can drive a sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
