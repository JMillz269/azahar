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
    @State private var pendingDelete: Int?

    /// Slot 0 is the quick slot, 1 to 10 are numbered.
    private static let slotNumbers = Array(0...10)

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.slotNumbers, id: \.self) { slot in
                    Button { choose(slot) } label: { row(for: slot) }
                        .disabled(mode == .load && !(slots[slot]?.isLoadable ?? false))
                        .swipeActions(edge: .trailing) {
                            if slots[slot] != nil {
                                Button(role: .destructive) { pendingDelete = slot } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if slots[slot] != nil {
                                Button(role: .destructive) { pendingDelete = slot } label: {
                                    Label("Delete State", systemImage: "trash")
                                }
                            }
                        }
                }
                Section {
                    NavigationLink {
                        SaveStateManagerView()
                    } label: {
                        Label("Manage All Save States", systemImage: "externaldrive")
                    }
                } footer: {
                    Text("Swipe a state to delete it. The manager lists the states of every game.")
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
            .confirmationDialog("Delete this state? It cannot be restored.", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let slot = pendingDelete {
                        _ = AZEmulator.shared.deleteSaveState(inSlot: slot)
                        reload()
                    }
                    pendingDelete = nil
                }
            }
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


// MARK: - Manager

/// Every save state of every game: see how much space they take and delete the ones that are not
/// needed. Opens from Settings, and from the save and load lists of a running game.
struct SaveStateManagerView: View {
    @EnvironmentObject private var library: GameLibrary

    @State private var entries: [AZSaveStateEntry] = []
    @State private var pendingDelete: AZSaveStateEntry?
    @State private var pendingDeleteGame: UInt64?
    @State private var pendingDeleteAll = false

    /// The games that have states, the one with the newest state first.
    private var programIDs: [UInt64] {
        var seen = Set<UInt64>()
        var result: [UInt64] = []
        for entry in entries where seen.insert(entry.programID).inserted {
            result.append(entry.programID)
        }
        return result
    }

    private func states(of programID: UInt64) -> [AZSaveStateEntry] {
        entries.filter { $0.programID == programID }
    }

    private func title(of programID: UInt64) -> String {
        library.games.first { $0.programID == programID }?.title
            ?? String(format: "Game %016llX", programID)
    }

    private func sizeText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func total(of list: [AZSaveStateEntry]) -> UInt64 {
        list.reduce(0) { $0 + UInt64($1.fileSize) }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    Text("There are no save states yet.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(LGRowBackground())
            }
            ForEach(programIDs, id: \.self) { programID in
                let list = states(of: programID)
                Section {
                    ForEach(list, id: \.self) { entry in
                        row(entry)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = entry } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    Button("Delete All for This Game", role: .destructive) {
                        pendingDeleteGame = programID
                    }
                } header: {
                    Text("\(title(of: programID)) · \(list.count) · \(sizeText(total(of: list)))")
                }
                .listRowBackground(LGRowBackground())
            }
            if !entries.isEmpty {
                Section {
                    LabeledContent("All Save States", value: sizeText(total(of: entries)))
                } footer: {
                    Text("Swipe a state to delete it. Deleting cannot be undone. States made by "
                         + "another version of the app are marked: they cannot be loaded.")
                }
                .listRowBackground(LGRowBackground())
            }
        }
        .navigationTitle("Save States")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { pendingDeleteAll = true } label: {
                        Label("Delete All Save States", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .lgSettingsStyle()
        .onAppear(perform: reload)
        .confirmationDialog("Delete this state? It cannot be restored.", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { delete([entry]) }
                pendingDelete = nil
            }
        }
        .confirmationDialog("Delete all save states of this game? They cannot be restored.",
                            isPresented: Binding(
            get: { pendingDeleteGame != nil },
            set: { if !$0 { pendingDeleteGame = nil } }), titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                if let programID = pendingDeleteGame { delete(states(of: programID)) }
                pendingDeleteGame = nil
            }
        }
        .confirmationDialog("Delete every save state of every game? They cannot be restored.",
                            isPresented: $pendingDeleteAll, titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) { delete(entries) }
        }
    }

    private func row(_ entry: AZSaveStateEntry) -> some View {
        HStack {
            Group {
                if let path = entry.thumbnailPath, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 58)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text((entry.slot == 0 ? "Quick Slot" : "Slot \(entry.slot)")
                     + (entry.movieID != 0 ? " · Movie" : ""))
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.isLoadable {
                    Text("Made by another version").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(sizeText(UInt64(entry.fileSize)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        entries = AZEmulator.allSaveStates()
    }

    private func delete(_ list: [AZSaveStateEntry]) {
        for entry in list {
            _ = AZEmulator.deleteSaveState(forProgram: entry.programID, movie: entry.movieID,
                                           slot: entry.slot)
        }
        reload()
    }
}
