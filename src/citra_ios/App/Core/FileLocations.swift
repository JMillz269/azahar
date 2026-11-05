// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Foundation

/// Locations of the app data. Everything lives in Documents so it is reachable from the Files app.
enum FileLocations {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Emulator user directory (sdmc, nand, sysdata, config, shaders, logs...).
    static var userDirectory: URL {
        documents.appendingPathComponent("Azahar", isDirectory: true)
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

    static func createDirectories() {
        for url in [userDirectory, romsDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
