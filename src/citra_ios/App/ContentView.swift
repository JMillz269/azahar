// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

/// Root view: the library and settings tabs, swapped for the emulation view while a game runs.
struct ContentView: View {
    @EnvironmentObject private var session: EmulationSession

    var body: some View {
        Group {
            if session.isActive {
                EmulationView()
                    .transition(.opacity)
            } else {
                TabView {
                    GamesListView()
                        .tabItem { Label("Games", systemImage: "gamecontroller.fill") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.isActive)
        .alert("Emulation Error", isPresented: $session.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
    }
}
