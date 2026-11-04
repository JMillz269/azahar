// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import UIKit
import UniformTypeIdentifiers

/// Presents the system file picker and hands back local copies of the chosen files.
///
/// The picker is shown straight from UIKit and asks the system to copy the files into the app's
/// temporary directory (`asCopy`). That avoids security scoped URLs, which do not work reliably
/// when the app runs inside another app such as LiveContainer, and does not depend on SwiftUI's
/// `fileImporter`, which silently drops its result when combined with other presentations.
@MainActor
final class DocumentImporter: NSObject, UIDocumentPickerDelegate {
    /// Keeps the importer alive while the picker is on screen (the picker only holds its delegate
    /// weakly).
    private static var active: DocumentImporter?

    private let completion: @MainActor ([URL]) -> Void

    private init(completion: @escaping @MainActor ([URL]) -> Void) {
        self.completion = completion
    }

    /// Shows the picker. `completion` is called with the copied files, or not at all if the
    /// picker is cancelled. Returns false if there was nothing to present the picker from.
    @discardableResult
    static func present(completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        guard active == nil, let presenter = topViewController() else { return false }

        let importer = DocumentImporter(completion: completion)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = importer
        active = importer
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
            DocumentImporter.active = nil
            completion(urls)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            DocumentImporter.active = nil
        }
    }
}
