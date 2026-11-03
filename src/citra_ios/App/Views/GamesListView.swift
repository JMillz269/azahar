// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI
import UniformTypeIdentifiers

/// The game library: a list or grid of the imported games.
struct GamesListView: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: EmulationSession

    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var gamePendingDeletion: Game?
    @State private var selectedGameInfo: Game?

    private var filteredGames: [Game] {
        guard !searchText.isEmpty else { return library.games }
        return library.games.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.publisher.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.games.isEmpty && !library.isScanning {
                    EmptyLibraryView { showingImporter = true }
                } else if settings.libraryStyle == .grid {
                    gridView
                } else {
                    listView
                }
            }
            .navigationTitle("Games")
            .searchable(text: $searchText, prompt: "Search games")
            .refreshable { library.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Library Style", selection: $settings.libraryStyle) {
                            ForEach(LibraryStyle.allCases) { style in
                                Label(style.title,
                                      systemImage: style == .list ? "list.bullet" : "square.grid.2x2")
                                    .tag(style)
                            }
                        }
                    } label: {
                        Image(systemName: settings.libraryStyle == .list
                              ? "list.bullet" : "square.grid.2x2")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import games")
                }
            }
            .overlay {
                if library.isScanning && library.games.isEmpty {
                    ProgressView("Scanning…")
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                library.importFiles(urls)
            }
        }
        .alert("Delete Game?", isPresented: Binding(
            get: { gamePendingDeletion != nil },
            set: { if !$0 { gamePendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let game = gamePendingDeletion { library.delete(game) }
                gamePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { gamePendingDeletion = nil }
        } message: {
            Text("\(gamePendingDeletion?.title ?? "") will be removed from this device.")
        }
        .alert("Import Failed", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
        .sheet(item: $selectedGameInfo) { game in
            GameInfoView(game: game)
        }
    }

    private var listView: some View {
        List(filteredGames) { game in
            Button {
                session.launch(game, settings: settings)
            } label: {
                GameRowView(game: game)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(for: game) }
        }
        .listStyle(.plain)
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)],
                      spacing: 16) {
                ForEach(filteredGames) { game in
                    Button {
                        session.launch(game, settings: settings)
                    } label: {
                        GameCardView(game: game)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: game) }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        Button {
            session.launch(game, settings: settings)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            selectedGameInfo = game
        } label: {
            Label("Game Info", systemImage: "info.circle")
        }
        Button(role: .destructive) {
            gamePendingDeletion = game
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Games Found")
                .font(.title2.bold())
            Text("Tap the + button to add your legally dumped and decrypted 3DS games, "
                 + "or copy them into the ROMs folder in the Files app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: onImport) {
                Label("Import Games", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GameInfoView: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        GameIconView(icon: game.icon, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title).font(.headline)
                            Text(game.publisher).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Details") {
                    LabeledContent("Title ID", value: game.programIDString)
                    LabeledContent("Region", value: game.regions)
                    LabeledContent("File Type", value: game.fileType)
                    LabeledContent("File", value: game.url.lastPathComponent)
                }
            }
            .navigationTitle("Game Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
