// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import UIKit
import UniformTypeIdentifiers

/// A folder chosen to hold the console's data (the nand and the virtual SD card) instead of the
/// Azahar folder of the app. The folder is remembered as a security scoped bookmark and its
/// access stays open while the app runs.
@MainActor
final class CustomStorage: NSObject, UIDocumentPickerDelegate {
    private static let key = "customStorageBookmark"
    private static var active: CustomStorage?
    private static var accessed: URL?

    private let completion: @MainActor (URL?) -> Void

    private init(completion: @escaping @MainActor (URL?) -> Void) {
        self.completion = completion
    }

    /// The folder in use, if one was chosen and it can still be reached.
    static var currentURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return url
    }

    /// Opens the access to the folder and returns its path for the emulator, or nil to use the
    /// default folder.
    static func activate() -> String? {
        guard let url = currentURL else { return nil }
        if accessed != url {
            accessed?.stopAccessingSecurityScopedResource()
            _ = url.startAccessingSecurityScopedResource()
            accessed = url
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url.path
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
    }

    /// Shows the folder picker. `completion` gets the chosen folder.
    @discardableResult
    static func choose(completion: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard active == nil, let presenter = topViewController() else { return false }
        let chooser = CustomStorage(completion: completion)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = chooser
        picker.allowsMultipleSelection = false
        active = chooser
        presenter.present(picker, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    nonisolated func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        Task { @MainActor in
            let completion = self.completion
            CustomStorage.active = nil
            guard let url = urls.first else { return completion(nil) }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let bookmark = try? url.bookmarkData() {
                UserDefaults.standard.set(bookmark, forKey: CustomStorage.key)
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            CustomStorage.active = nil
        }
    }
}
