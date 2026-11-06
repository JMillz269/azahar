// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// The 3DS Mii selector: a list of the Miis of the console to pick one from.
struct MiiSelectorView: View {
    let request: AZMiiRequest
    let onFinished: () -> Void

    @State private var selection = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(request.names.enumerated()), id: \.offset) { index, name in
                    Button {
                        selection = index
                    } label: {
                        HStack {
                            Text(name.isEmpty ? "Mii \(index + 1)" : name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if index == selection {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle(request.title.isEmpty ? "Select a Mii" : request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if request.allowsCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { finish(-1) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") { finish(selection) }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { selection = Int(request.initialIndex) }
    }

    private func finish(_ index: Int) {
        request.submit(index)
        onFinished()
    }
}
