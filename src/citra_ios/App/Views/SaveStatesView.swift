// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// Save and load states of the running game.
struct SaveStatesView: View {
    enum Mode {
        case save, load

        var title: String { self == .save ? "Save State" : "Load State" }
    }

    let mode: Mode
    @EnvironmentObject private var session: EmulationSession
    @Environment(\.dismiss) private var dismiss

    @State private var slots: [Int: AZSaveStateSlot] = [:]
    @State private var pendingOverwrite: Int?
    @State private var pendingLoad: Int?

    /// Slot 0 is the quick slot, 1 to 10 are numbered.
    private static let slotNumbers = Array(0...10)

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.slotNumbers, id: \.self) { slot in
                    Button { choose(slot) } label: { row(for: slot) }
                        .disabled(mode == .load && !(slots[slot]?.isLoadable ?? false))
                }
                if mode == .load {
                    Section {
                        EmptyView()
                    } footer: {
                        Text("Save states are not a replacement for saving in the game, and are not "
                             + "guaranteed to work after the app is updated.")
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .confirmationDialog("Overwrite this state?", isPresented: Binding(
                get: { pendingOverwrite != nil },
                set: { if !$0 { pendingOverwrite = nil } }), titleVisibility: .visible
            ) {
                Button("Overwrite", role: .destructive) {
                    if let slot = pendingOverwrite { perform(slot) }
                    pendingOverwrite = nil
                }
            }
            .confirmationDialog("Load this state? Progress since you made the current state of "
                                + "the game that is not saved in the game is lost.",
                                isPresented: Binding(
                get: { pendingLoad != nil },
                set: { if !$0 { pendingLoad = nil } }), titleVisibility: .visible
            ) {
                Button("Load") {
                    if let slot = pendingLoad { perform(slot) }
                    pendingLoad = nil
                }
            }
        }
    }

    /// The picture kept with a state, or a placeholder for one saved before pictures were kept.
    @ViewBuilder
    private func thumbnail(of state: AZSaveStateSlot?) -> some View {
        Group {
            if let path = state?.thumbnailPath, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: state == nil ? "tray" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 58)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(for slot: Int) -> some View {
        HStack {
            thumbnail(of: slots[slot])
            VStack(alignment: .leading, spacing: 2) {
                Text(slot == 0 ? "Quick Slot" : "Slot \(slot)")
                    .foregroundStyle(.primary)
                if let state = slots[slot] {
                    Text(state.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(state.isLoadable ? Color.secondary : Color.red)
                    if !state.isLoadable {
                        Text("Made by another version").font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("Empty").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: mode == .save ? "square.and.arrow.down" : "square.and.arrow.up")
                .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        slots = Dictionary(
            uniqueKeysWithValues: AZEmulator.shared.saveStateSlots().map { (Int($0.slot), $0) })
    }

    private func choose(_ slot: Int) {
        switch mode {
        case .save:
            if slots[slot] != nil { pendingOverwrite = slot } else { perform(slot) }
        case .load:
            pendingLoad = slot
        }
    }

    private func perform(_ slot: Int) {
        switch mode {
        case .save: session.saveState(slot: slot)
        case .load: session.loadState(slot: slot)
        }
        dismiss()
    }
}
