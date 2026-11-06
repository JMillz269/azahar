// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// The 3DS software keyboard: a prompt for the text a game asks for.
struct KeyboardPromptView: View {
    let request: AZKeyboardRequest
    let onFinished: () -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var maxLength: Int { request.maxLength > 0 ? Int(request.maxLength) : .max }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field
                } footer: {
                    if let message = error ?? request.errorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else if request.maxLength > 0 {
                        Text("\(text.count) / \(request.maxLength)")
                    }
                }

                Section {
                    ForEach(Array(request.buttonTexts.enumerated()), id: \.offset) { index, label in
                        Button(label) { press(index) }
                            .fontWeight(index == Int(request.confirmButtonIndex) ? .semibold : .regular)
                    }
                }
            }
            .navigationTitle("Enter Text")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        let placeholder = request.hintText
        if request.multiline {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
                .onChange(of: text) { limit($0) }
        } else {
            TextField(placeholder, text: $text)
                .keyboardType(request.numeric ? .numberPad : .default)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { press(Int(request.confirmButtonIndex)) }
                .submitLabel(.done)
                .onChange(of: text) { limit($0) }
        }
    }

    private func limit(_ value: String) {
        error = nil
        if value.count > maxLength {
            text = String(value.prefix(maxLength))
        }
    }

    private func press(_ index: Int) {
        if let message = request.submit(text, index) {
            error = message
        } else {
            onFinished()
        }
    }
}
