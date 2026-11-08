// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// Full screen emulation: the rendered 3DS screens, the on-screen controller and a menu.
struct EmulationView: View {
    @EnvironmentObject private var session: EmulationSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controllerLayout: ControllerLayoutStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingMenu = false
    @State private var controllerVisible = true
    /// Keeps the on-screen controller up although a physical one is connected (until it changes).
    @State private var showDespiteHardware = false
    @State private var pausedForBackground = false
    @State private var editingLayout = false
    @State private var showingSaveStates = false
    @State private var showingLoadStates = false
    @State private var showingCheats = false
    @State private var showingAmiibo = false
    @State private var showingMultiplayer = false
    @State private var showingMovies = false
    @State private var editingScreens = false
    @State private var resumeAfterEditing = false
    /// The game was paused because the menu came up, and runs again once it is gone.
    @State private var pausedForMenu = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // By default stays inside the safe area so the screens do not go under the notch or
            // the Dynamic Island. The black background behind it still fills the whole display.
            MetalView {
                session.renderSurfaceReady()
            }
            .ignoresSafeArea(settings.respectNotch ? [] : .all)

            if editingScreens {
                ScreenLayoutEditor(isEditing: $editingScreens)
                    .ignoresSafeArea(settings.respectNotch ? [] : .all)
            }

            if controllerShown && !editingScreens {
                ControllerOverlay(opacity: settings.controllerOpacity,
                                  haptics: settings.hapticFeedback,
                                  isEditing: $editingLayout)
            }

            VStack {
                HStack(alignment: .top) {
                    if settings.showPerformanceOverlay {
                        PerformanceOverlay(fps: session.fps, speed: session.speed, gpuMs: session.gpuMs,
                                           stallMs: session.stallMs, draws: session.draws,
                                           paceJitterMs: session.paceJitterMs)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            // Placed with the controller layout, so it can be moved in the layout editor (which
            // draws it itself while editing).
            if !editingLayout && !editingScreens {
                GeometryReader { geometry in
                    let metrics = ControllerMetrics(size: geometry.size)
                    let placement = controllerLayout.placement(for: .menuButton,
                                                               portrait: metrics.portrait)
                    let frame = metrics.frame(of: .menuButton, placement: placement)
                    Button {
                        showingMenu = true
                    } label: {
                        MenuButtonIcon(scale: CGFloat(placement.scale))
                            .frame(width: frame.width, height: frame.height)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Emulation menu")
                    .position(x: frame.midX, y: frame.midY)
                }
            }

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

            if let toast = session.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if session.isPaused && !editingLayout {
                Text("Paused")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .onAppear {
            controllerLayout.activate(gameID: session.currentGame?.programIDString)
            RefreshRateController.shared.apply(settings.refreshRate)
        }
        .onDisappear {
            controllerLayout.activate(gameID: nil)
            RefreshRateController.shared.apply(.automatic)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openEmulationMenu)) { _ in
            showingMenu = true
        }
        .onChange(of: session.hardwareControllerConnected) { _ in showDespiteHardware = false }
        .onChange(of: settings.refreshRate) { RefreshRateController.shared.apply($0) }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Without this iOS holds back touches near the screen edges until it knows they are not
        // a system swipe (Home, Control Center, Notification Center), then delivers the press
        // and the release together, so the game never sees a quick tap on the controller.
        .defersSystemGestures(on: .all)
        .confirmationDialog(session.currentGame?.title ?? "Emulation",
                            isPresented: $showingMenu, titleVisibility: .visible) {
            if pausedForMenu {
                // The game is paused while the menu is up. Leaving it paused afterwards is a choice.
                Button("Keep Paused") { pausedForMenu = false }
            }
            Button(session.isPaused ? "Resume" : "Pause") {
                pausedForMenu = false
                session.togglePause()
            }
            Button(controllerShown ? "Hide Controller" : "Show Controller") {
                if controllerShown {
                    controllerVisible = false
                } else {
                    controllerVisible = true
                    showDespiteHardware = true
                }
            }
            if settings.showController {
                Button("Edit Controller Layout") { beginEditingLayout() }
            }
            Button("Save State…") { showingSaveStates = true }
            Button("Load State…") { showingLoadStates = true }
            Button("Cheats…") { showingCheats = true }
            Button("Amiibo…") { showingAmiibo = true }
            Button("Multiplayer…") { showingMultiplayer = true }
            Button("Movies…") { showingMovies = true }
            Button(session.isFastForwarding ? "Normal Speed" : "Fast Forward") {
                session.toggleFastForward()
            }
            Button("Take Screenshot") { session.takeScreenshot() }
            Button("Edit Screen Layout") { beginEditingScreens() }
            Button("Swap Screens") {
                settings.swapScreens.toggle()
                session.apply(settings: settings)
            }
            Button("Stop Emulation", role: .destructive) { session.stop() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingSaveStates) {
            SaveStatesView(mode: .save)
        }
        .sheet(isPresented: $showingLoadStates) {
            SaveStatesView(mode: .load)
        }
        .sheet(isPresented: $showingCheats) {
            CheatsView()
        }
        .sheet(isPresented: $showingAmiibo) {
            AmiiboView()
        }
        .sheet(isPresented: $showingMultiplayer) {
            MultiplayerView()
        }
        .sheet(isPresented: $showingMovies) {
            if let game = session.currentGame {
                MoviesView(game: game)
            }
        }
        .sheet(item: $session.miiRequest) { request in
            MiiSelectorView(request: request) { session.miiRequest = nil }
        }
        .sheet(item: $session.keyboardRequest) { request in
            KeyboardPromptView(request: request) { session.keyboardRequest = nil }
        }
        .alert(session.notice?.title ?? "", isPresented: Binding(
            get: { session.notice != nil },
            set: { if !$0 { session.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.notice?.message ?? "")
        }
        .onChange(of: menuVisible) { visible in
            menuVisibilityChanged(visible)
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
    /// Whether the menu, or something it opened that the game should wait for, is on screen. The
    /// multiplayer room is not part of it: the others in the room keep playing.
    fileprivate var menuVisible: Bool {
        showingMenu || showingSaveStates || showingLoadStates || showingCheats || showingAmiibo
            || showingMovies || editingLayout
    }

    /// Pauses the game while the menu is up and runs it again when it is gone.
    fileprivate func menuVisibilityChanged(_ visible: Bool) {
        resumeTask?.cancel()
        resumeTask = nil
        if visible {
            // A game that was paused already stays paused afterwards.
            if !session.isPaused {
                session.togglePause()
                pausedForMenu = true
            }
            return
        }
        guard pausedForMenu else { return }
        // The menu hands over to the screen of the choice (save states, cheats) in a moment where
        // neither shows, wait a little so the game does not run in between.
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, !menuVisible, pausedForMenu else { return }
            pausedForMenu = false
            if session.isPaused {
                session.togglePause()
            }
        }
    }

    /// Whether the on-screen controller is drawn: it is hidden by the menu, and while a physical
    /// controller is connected (when the setting says so).
    fileprivate var controllerShown: Bool {
        guard settings.showController && controllerVisible else { return false }
        let hiddenByHardware = settings.hideControllerWithHardware
            && session.hardwareControllerConnected && !showDespiteHardware
        return !hiddenByHardware
    }

    /// Switches the current orientation to the custom layout and lets the screens be moved.
    fileprivate func beginEditingScreens() {
        let portrait = UIScreen.main.bounds.height > UIScreen.main.bounds.width
        if portrait {
            settings.portraitLayout = .custom
        } else {
            settings.layout = .custom
        }
        session.apply(settings: settings)
        AZEmulator.shared.refreshLayout()
        editingScreens = true
    }

    /// Pauses the game and lets the controller be moved and resized.
    fileprivate func beginEditingLayout() {
        controllerVisible = true
        showDespiteHardware = true
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
    let paceJitterMs: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS %.0f", fps))
            Text(String(format: "Speed %.0f%%", speed))
            Text(String(format: "GPU %.1f ms", gpuMs))
            Text(String(format: "Wait %.1f ms", stallMs))
            Text(String(format: "Pace ±%.1f ms", paceJitterMs))
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
