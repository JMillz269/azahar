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
    @EnvironmentObject private var compressor: GameCompressor

    @State private var searchText = ""
    @State private var gamePendingDeletion: Game?
    @State private var selectedGameInfo: Game?
    @State private var showingArtic = false

    /// Shows the file picker. The picked files are copied by the system first, so a failure can
    /// only happen before the import starts.
    private func importGames() {
        let presented = DocumentImporter.present { urls in
            library.importFiles(urls)
        }
        if !presented {
            library.importError = "The file picker could not be opened."
        }
    }

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
                    EmptyLibraryView { importGames() }
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
                        showingArtic = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("Artic: stream from a 3DS")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        importGames()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import games or install CIAs")
                }
            }
            .overlay {
                if compressor.isRunning, let name = compressor.currentName {
                    VStack(spacing: 10) {
                        Text("Compressing")
                            .font(.headline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(value: compressor.progress)
                            .frame(width: 220)
                        Text("\(Int((compressor.progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if let name = library.installName {
                    VStack(spacing: 10) {
                        Text("Installing")
                            .font(.headline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(value: library.installProgress)
                            .frame(width: 220)
                        Text("\(Int((library.installProgress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if library.isImporting {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if library.isScanning && library.games.isEmpty {
                    ProgressView("Scanning…")
                }
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
        .alert("Installed", isPresented: Binding(
            get: { library.installSummary != nil },
            set: { if !$0 { library.installSummary = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.installSummary ?? "")
        }
        .sheet(isPresented: $showingArtic) {
            ArticView()
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
        if let compressed = game.compressedExtension {
            Button {
                compressor.compress([game.url],
                                    deleteSources: !settings.keepOriginalsWhenCompressing,
                                    library: library)
            } label: {
                Label("Convert to .\(compressed)", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(compressor.isRunning)
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
                Section {
                    NavigationLink {
                        GameSettingsView(game: game)
                    } label: {
                        Label("Game Settings", systemImage: "slider.horizontal.3")
                    }
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
