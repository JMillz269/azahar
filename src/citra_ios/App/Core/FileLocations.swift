// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Foundation
import UIKit

/// Locations of the app data. Everything lives in Documents so it is reachable from the Files app.
enum FileLocations {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Emulator user directory (sdmc, nand, sysdata, config, shaders, logs...).
    static var userDirectory: URL {
        documents.appendingPathComponent("Azahar", isDirectory: true)
    }

    /// Shows a folder in the Files app (inside this app's Documents, which is where the Files app
    /// lists the app's data). Falls back to opening the Files app.
    @MainActor
    static func showInFiles(_ url: URL) {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        if let target = URL(string: "shareddocuments://" + path) {
            UIApplication.shared.open(target) { opened in
                if !opened, let files = URL(string: "shareddocuments://") {
                    UIApplication.shared.open(files)
                }
            }
        }
    }

    /// Imported games.
    static var romsDirectory: URL {
        documents.appendingPathComponent("ROMs", isDirectory: true)
    }

    /// File extensions the emulator can boot.
    static let bootableExtensions: Set<String> = [
        "3ds", "cci", "cxi", "3dsx", "app", "elf", "axf", "zcci", "zcxi", "z3dsx",
    ]

    /// Metal shader caches of every game (see the Metal PipelineCache).
    static var shaderCacheDirectory: URL {
        userDirectory.appendingPathComponent("shaders/metal", isDirectory: true)
    }

    /// Deletes the shader caches. Returns true so it can drive a confirmation alert.
    @discardableResult
    static func clearShaderCache() -> Bool {
        try? FileManager.default.removeItem(at: shaderCacheDirectory)
        return true
    }

    /// The amiibo files the app keeps. A game saves what it writes to an amiibo into its file.
    static var amiiboDirectory: URL {
        userDirectory.appendingPathComponent("amiibo", isDirectory: true)
    }

    /// Screenshots taken in a game.
    static var screenshotsDirectory: URL {
        userDirectory.appendingPathComponent("screenshots", isDirectory: true)
    }

    /// Installable titles (games, updates and DLC) the emulator installs instead of importing.
    static let ciaExtensions: Set<String> = ["cia", "zcia"]

    /// Where the installed titles live.
    static var installedTitlesDirectory: URL {
        userDirectory.appendingPathComponent("sdmc/Nintendo 3DS", isDirectory: true)
    }

    static func createDirectories() {
        for url in [userDirectory, romsDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
