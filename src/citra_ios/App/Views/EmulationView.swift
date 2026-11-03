// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

/// Full screen emulation: the rendered 3DS screens, the on-screen controller and a menu.
struct EmulationView: View {
    @EnvironmentObject private var session: EmulationSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingMenu = false
    @State private var controllerVisible = true
    @State private var pausedForBackground = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalView {
                session.renderSurfaceReady()
            }
            .ignoresSafeArea()

            if settings.showController && controllerVisible {
                ControllerOverlay(opacity: settings.controllerOpacity,
                                  haptics: settings.hapticFeedback)
            }

            VStack {
                HStack(alignment: .top) {
                    if settings.showPerformanceOverlay {
                        PerformanceOverlay(fps: session.fps, speed: session.speed)
                    }
                    Spacer()
                    Button {
                        showingMenu = true
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    .accessibilityLabel("Emulation menu")
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            if session.isPaused {
                Text("Paused")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .confirmationDialog(session.currentGame?.title ?? "Emulation",
                            isPresented: $showingMenu, titleVisibility: .visible) {
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
            Button(controllerVisible ? "Hide Controller" : "Show Controller") {
                controllerVisible.toggle()
            }
            Button("Swap Screens") {
                settings.swapScreens.toggle()
                session.apply(settings: settings)
            }
            Button("Stop Emulation", role: .destructive) { session.stop() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background, .inactive:
                if !session.isPaused {
                    session.togglePause()
                    pausedForBackground = true
                }
            case .active:
                if pausedForBackground && session.isPaused {
                    session.togglePause()
                }
                pausedForBackground = false
            @unknown default:
                break
            }
        }
    }
}

private struct PerformanceOverlay: View {
    let fps: Double
    let speed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS %.0f", fps))
            Text(String(format: "Speed %.0f%%", speed))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
