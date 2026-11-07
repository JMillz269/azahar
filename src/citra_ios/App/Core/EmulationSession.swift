// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AVFoundation
import AzaharCore
import Foundation
import UIKit

/// Drives the emulator from the UI: launching, pausing, stopping and statistics.
@MainActor
final class EmulationSession: ObservableObject {
    @Published private(set) var currentGame: Game?
    @Published private(set) var isPaused = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var speed: Double = 0
    /// Progress of building the cached shaders while the game boots, nil when not building.
    @Published private(set) var shaderBuildProgress: Double?
    /// Average GPU time and time the emulation thread waited for the GPU, per frame, in ms.
    @Published private(set) var gpuMs: Double = 0
    @Published private(set) var stallMs: Double = 0
    @Published private(set) var paceJitterMs: Double = 0
    @Published private(set) var draws: Double = 0
    /// The software keyboard of the running game, while it waits for text.
    @Published var keyboardRequest: AZKeyboardRequest?
    /// The Mii selector of the running game, while it waits for a choice.
    @Published var miiRequest: AZMiiRequest?
    /// A message for the user that does not end the game.
    @Published var notice: SessionNotice?
    /// A short confirmation shown over the game for a moment.
    @Published private(set) var toast: String?
    @Published var showingError = false
    @Published private(set) var errorMessage: String?
    /// Complete report of an exception in the emulated program, when there is one.
    @Published private(set) var errorReport: String?

    /// Whether a physical game controller is connected while a game runs.
    @Published private(set) var hardwareControllerConnected = false

    let controllers = GameControllerInput()
    let motion = MotionInput()

    private var pendingGame: Game?
    private var pendingSettings: AppSettings?
    private var statsTimer: Timer?

    var isActive: Bool { currentGame != nil }

    init() {
        controllers.onConnectionChange = { [weak self] connected in
            self?.hardwareControllerConnected = connected
        }
        controllers.onHotkey = { [weak self] hotkey in
            Task { @MainActor in
                self?.perform(hotkey)
            }
        }
        AZEmulator.shared.onStopped = { [weak self] error in
            Task { @MainActor in
                self?.handleStopped(error: error)
            }
        }
        AZEmulator.shared.onKeyboardRequest = { [weak self] request in
            Task { @MainActor in
                self?.keyboardRequest = request
            }
        }
        AZEmulator.shared.onMiiRequest = { [weak self] request in
            Task { @MainActor in
                self?.miiRequest = request
            }
        }
        AZEmulator.shared.onNotice = { [weak self] title, message in
            Task { @MainActor in
                self?.notice = SessionNotice(title: title, message: message)
            }
        }
    }

    // MARK: Save states and cheats

    func saveState(slot: Int) {
        if AZEmulator.shared.saveState(toSlot: slot) {
            showToast(slot == 0 ? "Saved to the quick slot" : "Saved to slot \(slot)")
        } else {
            notice = SessionNotice(title: "Save State", message: "The state could not be saved right now.")
        }
    }

    func loadState(slot: Int) {
        if AZEmulator.shared.loadState(fromSlot: slot) {
            showToast(slot == 0 ? "Loaded the quick slot" : "Loaded slot \(slot)")
        } else {
            notice = SessionNotice(title: "Load State", message: "The state could not be loaded right now.")
        }
    }

    // MARK: Amiibo, screenshots and speed

    @Published private(set) var isFastForwarding = false

    func toggleFastForward() {
        isFastForwarding.toggle()
        AZEmulator.shared.setFastForward(isFastForwarding)
        showToast(isFastForwarding ? "Fast forward on" : "Fast forward off")
    }

    /// What a controller shortcut does.
    private func perform(_ hotkey: Hotkey) {
        guard isActive else { return }
        switch hotkey {
        case .menu: NotificationCenter.default.post(name: .openEmulationMenu, object: nil)
        case .fastForward: toggleFastForward()
        case .screenshot: takeScreenshot()
        }
    }

    func takeScreenshot() {
        AZEmulator.shared.takeScreenshot(toDirectory: FileLocations.screenshotsDirectory.path) {
            [weak self] path in
            Task { @MainActor in
                self?.showToast(path != nil
                    ? "Screenshot saved to Files › Azahar › screenshots"
                    : "The screenshot failed")
            }
        }
    }

    func loadAmiibo(at url: URL) {
        switch AZEmulator.shared.loadAmiibo(atPath: url.path) {
        case .loaded:
            showToast("Amiibo loaded")
        case .notSearching:
            notice = SessionNotice(
                title: "Amiibo",
                message: "The game is not asking for an amiibo right now. Open the amiibo screen in "
                    + "the game first, then load it.")
        case .tagInUse:
            notice = SessionNotice(
                title: "Amiibo", message: "An amiibo is already on the reader. Remove it first.")
        case .notRunning, .failed:
            notice = SessionNotice(title: "Amiibo", message: "The amiibo could not be loaded.")
        @unknown default:
            break
        }
    }

    func removeAmiibo() {
        AZEmulator.shared.removeAmiibo()
        showToast("Amiibo removed")
    }

    private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                toast = nil
            }
        }
    }

    /// Shows the emulation view. The emulator itself starts once the Metal view is ready.
    func launch(_ game: Game, settings: AppSettings) {
        guard currentGame == nil else { return }
        if game.isEncrypted {
            present(error: "\(game.title) is encrypted. Please dump your titles from your own "
                + "console in a decrypted format.")
            return
        }
        pendingGame = game
        pendingSettings = settings
        currentGame = game
        isPaused = false
    }

    /// Called by the Metal view once its layer has a valid size.
    func renderSurfaceReady() {
        guard let game = pendingGame, let settings = pendingSettings else { return }
        pendingGame = nil
        pendingSettings = nil

        if !AZEmulator.isJITAvailable && (settings.cpuJIT || settings.shaderJIT) {
            NSLog("Azahar: JIT is not available, falling back to the interpreters")
        }
        AZEmulator.shared.apply(configuration: settings.makeConfiguration(for: game))
        do {
            try AZEmulator.shared.start(path: game.startPath)
        } catch {
            currentGame = nil
            present(error: error.localizedDescription)
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        prepareAudioSession(recording: settings.useMicrophone)
        controllers.start()
        if settings.useMotion {
            motion.start()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = AZEmulator.shared.framesPerSecond
                self.speed = AZEmulator.shared.emulationSpeed
                self.gpuMs = AZEmulator.shared.gpuMilliseconds
                self.stallMs = AZEmulator.shared.stallMilliseconds
                self.paceJitterMs = AZEmulator.shared.paceJitterMilliseconds
                self.draws = AZEmulator.shared.drawsPerFrame
                let progress = AZEmulator.shared.shaderBuildProgress
                self.shaderBuildProgress = progress >= 0 ? progress : nil
            }
        }
    }

    func togglePause() {
        if isPaused {
            AZEmulator.shared.resume()
        } else {
            AZEmulator.shared.pause()
        }
        isPaused.toggle()
    }

    func stop() {
        pendingGame = nil
        AZEmulator.shared.stop()
        cleanUp()
    }

    /// Applies changed settings to the running game where possible.
    func apply(settings: AppSettings) {
        guard let game = currentGame else { return }
        AZEmulator.shared.apply(configuration: settings.makeConfiguration(for: game))
    }

    private func handleStopped(error: Error?) {
        cleanUp()
        if let error {
            let report = (error as NSError).userInfo["AZEmulatorErrorReport"] as? String
            present(error: error.localizedDescription, report: report)
        }
    }

    /// Playback only, or playback and recording when the game may use the microphone. Recording
    /// asks for permission the first time.
    private func prepareAudioSession(recording: Bool) {
        let audio = AVAudioSession.sharedInstance()
        guard recording else {
            try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? audio.setActive(true)
            return
        }
        audio.requestRecordPermission { granted in
            Task { @MainActor in
                let category: AVAudioSession.Category = granted ? .playAndRecord : .playback
                var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
                if granted { options.insert(.defaultToSpeaker) }
                try? audio.setCategory(category, mode: .default, options: options)
                try? audio.setActive(true)
            }
        }
    }

    private func cleanUp() {
        prepareAudioSession(recording: false)
        statsTimer?.invalidate()
        statsTimer = nil
        controllers.stop()
        motion.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        currentGame = nil
        isFastForwarding = false
        keyboardRequest = nil
        miiRequest = nil
        isPaused = false
        fps = 0
        speed = 0
    }

    private func present(error: String, report: String? = nil) {
        errorMessage = error
        errorReport = report
        showingError = true
    }
}

/// A message shown to the user in an alert.
struct SessionNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension AZMiiRequest: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension AZKeyboardRequest: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension Notification.Name {
    /// Asks the game view to show its menu (a controller shortcut).
    static let openEmulationMenu = Notification.Name("azahar.openEmulationMenu")
}
