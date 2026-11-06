// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// The cheats of the running game: switch them on and off, add, edit and delete them.
struct CheatsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cheats: [AZCheat] = []
    @State private var editing: EditTarget?

    private struct EditTarget: Identifiable {
        let id = UUID()
        /// Index of the cheat being edited, nil for a new one.
        let index: Int?
        let cheat: AZCheat
    }

    var body: some View {
        NavigationStack {
            List {
                if cheats.isEmpty {
                    Section {
                        Text("No cheats for this game yet. Add one with the + button, using Gateway "
                             + "codes (one \"XXXXXXXX XXXXXXXX\" pair per line).")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(cheats.enumerated()), id: \.offset) { index, cheat in
                    HStack {
                        Button {
                            editing = EditTarget(index: index, cheat: cheat)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cheat.name.isEmpty ? "Unnamed cheat" : cheat.name)
                                    .foregroundStyle(.primary)
                                if !cheat.comments.isEmpty {
                                    Text(cheat.comments)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cheat.enabled },
                            set: { enabled in
                                cheat.enabled = enabled
                                AZEmulator.shared.setCheatEnabled(enabled, at: index)
                                reload()
                            }))
                            .labelsHidden()
                    }
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        AZEmulator.shared.removeCheat(at: index)
                    }
                    reload()
                }
            }
            .navigationTitle("Cheats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let cheat = AZCheat()
                        cheat.name = ""
                        cheat.code = ""
                        cheat.comments = ""
                        cheat.enabled = false
                        editing = EditTarget(index: nil, cheat: cheat)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add cheat")
                }
            }
            .onAppear(perform: reload)
            .sheet(item: $editing, onDismiss: reload) { target in
                CheatEditor(index: target.index, cheat: target.cheat)
            }
        }
    }

    private func reload() {
        cheats = AZEmulator.shared.cheats()
    }
}

private struct CheatEditor: View {
    let index: Int?
    let cheat: AZCheat

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var comments = ""
    @State private var invalidLines: [Int] = []
    @State private var confirmInvalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    TextEditor(text: $code)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(minHeight: 140)
                } header: {
                    Text("Gateway Code")
                } footer: {
                    if invalidLines.isEmpty {
                        Text("One \"XXXXXXXX XXXXXXXX\" pair per line.")
                    } else {
                        Text("Line \(invalidLines.map(String.init).joined(separator: ", ")) is not a "
                             + "valid code line.")
                            .foregroundStyle(.red)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $comments, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(index == nil ? "New Cheat" : "Edit Cheat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = cheat.name
                code = cheat.code
                comments = cheat.comments
            }
            .onChange(of: code) { _ in invalidLines = [] }
            .confirmationDialog("Some lines are not valid codes. Save the cheat anyway?",
                                isPresented: $confirmInvalid, titleVisibility: .visible) {
                Button("Save Anyway", role: .destructive) { commit() }
            }
        }
    }

    private func save() {
        invalidLines = AZEmulator.invalidCheatLines(inCode: code).map(\.intValue)
        if invalidLines.isEmpty {
            commit()
        } else {
            confirmInvalid = true
        }
    }

    private func commit() {
        let result = AZCheat()
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        result.comments = comments
        result.enabled = cheat.enabled
        if let index {
            AZEmulator.shared.replaceCheat(at: index, with: result)
        } else {
            AZEmulator.shared.addCheat(result)
        }
        dismiss()
    }
}
