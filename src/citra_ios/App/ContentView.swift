// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI
import UIKit

/// The two sections of the root view.
private enum RootTab {
    case games
    case settings
}

/// Root view: the library and settings, swapped for the emulation view while a game runs.
///
/// The sections use a small bar of our own rather than a TabView: building the system tab bar
/// overflowed the 1 MB main thread stack at launch when running inside LiveContainer.
struct ContentView: View {
    @EnvironmentObject private var session: EmulationSession
    @State private var tab = RootTab.games

    var body: some View {
        Group {
            if session.isActive {
                EmulationView()
            } else {
                VStack(spacing: 0) {
                    Group {
                        if tab == .games {
                            GamesListView()
                        } else {
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    RootTabBar(tab: $tab)
                }
            }
        }
        .alert("Emulation Error", isPresented: $session.showingError) {
            if let report = session.errorReport {
                Button("Copy Details") { UIPasteboard.general.string = report }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
    }
}

/// The bar switching between the library and the settings.
private struct RootTabBar: View {
    @Binding var tab: RootTab

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                item("Games", symbol: "gamecontroller.fill", for: .games)
                item("Settings", symbol: "gearshape.fill", for: .settings)
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .background(.bar)
    }

    private func item(_ title: String, symbol: String, for value: RootTab) -> some View {
        Button {
            tab = value
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tab == value ? Color.accentColor : Color.secondary)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}
