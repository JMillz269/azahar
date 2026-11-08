// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// Records the controller input of a run to a movie file and plays movies back. A recording or a
/// playback starts together with the game, so starting one restarts the game.
struct MoviesView: View {
    let game: Game

    @EnvironmentObject private var session: EmulationSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private struct MovieFile: Identifiable {
        let url: URL
        let info: AZMovieInfo
        var id: URL { url }
    }

    @State private var movies: [MovieFile] = []
    @State private var mode = AZMovieMode.none
    @State private var name = ""
    @State private var author = ""
    @State private var pendingPlay: MovieFile?
    @State private var pendingRecord = false

    var body: some View {
        NavigationStack {
            Form {
                if mode == .recording || mode == .playing || mode == .finished {
                    Section {
                        LabeledContent("Movie", value: statusText)
                        if mode == .recording {
                            Button("Save Now") {
                                AZEmulator.shared.saveMovie()
                                session.showToast("Movie saved")
                            }
                        }
                        Button(mode == .recording ? "Stop and Save" : "Stop Playback") {
                            AZEmulator.shared.stopMovie()
                            session.showToast(mode == .recording ? "Movie saved" : "Playback stopped")
                            refresh()
                        }
                    } header: {
                        Text("Now")
                    }
                }

                Section {
                    TextField("Movie Name", text: $name)
                    TextField("Author", text: $author)
                    Button("Restart and Record") { pendingRecord = true }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Record")
                } footer: {
                    Text("The game restarts from the beginning and everything you press is "
                         + "recorded. Stop the recording from this screen, or it is saved when "
                         + "you stop the game.")
                }

                Section {
                    if movies.isEmpty {
                        Text("No movies of this game yet.").foregroundStyle(.secondary)
                    }
                    ForEach(movies) { movie in
                        Button { pendingPlay = movie } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.url.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(.primary)
                                Text(details(of: movie.info))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                try? FileManager.default.removeItem(at: movie.url)
                                refresh()
                            }
                        }
                    }
                    Button("Show Movies Folder in Files") {
                        FileLocations.showInFiles(FileLocations.moviesDirectory)
                    }
                } header: {
                    Text("Movies")
                } footer: {
                    Text("Tap a movie to play it: the game restarts and the recorded input plays.")
                }
            }
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if author.isEmpty { author = AZMultiplayer.shared.suggestedNickname }
                if name.isEmpty { name = defaultName() }
                refresh()
            }
            .confirmationDialog("Restart the game to record?", isPresented: $pendingRecord,
                                titleVisibility: .visible) {
                Button("Restart and Record") { startRecording() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Unsaved progress in the game is lost.")
            }
            .confirmationDialog(
                "Restart the game to play the movie?",
                isPresented: Binding(get: { pendingPlay != nil },
                                     set: { if !$0 { pendingPlay = nil } }),
                titleVisibility: .visible
            ) {
                Button("Restart and Play") {
                    if let movie = pendingPlay { startPlayback(movie) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Unsaved progress in the game is lost.")
            }
        }
    }

    private var statusText: String {
        switch mode {
        case .recording: return "Recording"
        case .playing: return "Playing"
        case .finished: return "Finished"
        default: return "None"
        }
    }

    private func details(of info: AZMovieInfo) -> String {
        var parts: [String] = []
        if !info.author.isEmpty { parts.append(info.author) }
        parts.append("\(info.inputCount) frames")
        if info.rerecordCount > 1 { parts.append("\(info.rerecordCount) re-records") }
        return parts.joined(separator: " · ")
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "\(game.title) \(formatter.string(from: Date()))"
    }

    private func refresh() {
        mode = AZEmulator.shared.movieMode
        let files = (try? FileManager.default.contentsOfDirectory(
            at: FileLocations.moviesDirectory, includingPropertiesForKeys: nil)) ?? []
        movies = files.filter { $0.pathExtension.lowercased() == "ctm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { MovieFile(url: $0, info: AZEmulator.movieInfo(atPath: $0.path)) }
            .filter { $0.info.isValid && $0.info.programID == game.programID }
    }

    private func startRecording() {
        try? FileManager.default.createDirectory(
            at: FileLocations.moviesDirectory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let url = FileLocations.moviesDirectory.appendingPathComponent(safe + ".ctm")
        AZEmulator.shared.recordMovie(toPath: url.path, author: author)
        dismiss()
        session.restartCurrentGame(settings: settings)
    }

    private func startPlayback(_ movie: MovieFile) {
        AZEmulator.shared.playMovie(fromPath: movie.url.path)
        dismiss()
        session.restartCurrentGame(settings: settings)
    }
}
