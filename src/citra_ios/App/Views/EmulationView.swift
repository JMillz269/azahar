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
    @State private var editingLayout = false
    @State private var resumeAfterEditing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // By default stays inside the safe area so the screens do not go under the notch or
            // the Dynamic Island. The black background behind it still fills the whole display.
            MetalView {
                session.renderSurfaceReady()
            }
            .ignoresSafeArea(settings.respectNotch ? [] : .all)

            if settings.showController && controllerVisible {
                ControllerOverlay(opacity: settings.controllerOpacity,
                                  haptics: settings.hapticFeedback,
                                  isEditing: $editingLayout)
            }

            VStack {
                HStack(alignment: .top) {
                    if settings.showPerformanceOverlay {
                        PerformanceOverlay(fps: session.fps, speed: session.speed, gpuMs: session.gpuMs,
                                           stallMs: session.stallMs, draws: session.draws)
                    }
                    Spacer()
                    if !editingLayout {
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
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            if let progress = session.shaderBuildProgress {
                VStack(spacing: 8) {
                    Text("Building Shaders")
                        .font(.headline)
                    ProgressView(value: progress)
                        .frame(width: 180)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
            }

            if session.isPaused && !editingLayout {
                Text("Paused")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Without this iOS holds back touches near the screen edges until it knows they are not
        // a system swipe (Home, Control Center, Notification Center), then delivers the press
        // and the release together, so the game never sees a quick tap on the controller.
        .defersSystemGestures(on: .all)
        .confirmationDialog(session.currentGame?.title ?? "Emulation",
                            isPresented: $showingMenu, titleVisibility: .visible) {
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
            Button(controllerVisible ? "Hide Controller" : "Show Controller") {
                controllerVisible.toggle()
            }
            if settings.showController {
                Button("Edit Controller Layout") { beginEditingLayout() }
            }
            Button("Swap Screens") {
                settings.swapScreens.toggle()
                session.apply(settings: settings)
            }
            Button("Stop Emulation", role: .destructive) { session.stop() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: editingLayout) { editing in
            if !editing && resumeAfterEditing {
                resumeAfterEditing = false
                if session.isPaused {
                    session.togglePause()
                }
            }
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

extension EmulationView {
    /// Pauses the game and lets the controller be moved and resized.
    fileprivate func beginEditingLayout() {
        controllerVisible = true
        if !session.isPaused {
            session.togglePause()
            resumeAfterEditing = true
        }
        editingLayout = true
    }
}

private struct PerformanceOverlay: View {
    let fps: Double
    let speed: Double
    let gpuMs: Double
    let stallMs: Double
    let draws: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS %.0f", fps))
            Text(String(format: "Speed %.0f%%", speed))
            Text(String(format: "GPU %.1f ms", gpuMs))
            Text(String(format: "Wait %.1f ms", stallMs))
            Text(String(format: "Draws %.0f", draws))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
