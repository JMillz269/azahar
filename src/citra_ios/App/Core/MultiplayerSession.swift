// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import Foundation

/// The multiplayer room as the views see it.
@MainActor
final class MultiplayerSession: ObservableObject {
    @Published private(set) var state = AZMultiplayerState.disconnected
    @Published private(set) var isHosting = false
    @Published private(set) var roomName = ""
    @Published private(set) var maxMembers = 0
    @Published private(set) var members: [String] = []
    @Published private(set) var messages: [String] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    var isInRoom: Bool { state == .joined || state == .moderator }
    var suggestedNickname: String { AZMultiplayer.shared.suggestedNickname }

    init() {
        AZMultiplayer.shared.onChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        let multiplayer = AZMultiplayer.shared
        state = multiplayer.state
        isHosting = multiplayer.isHosting
        roomName = multiplayer.roomName
        maxMembers = multiplayer.maxMembers
        members = multiplayer.members
        messages = multiplayer.messages
    }

    func join(address: String, port: Int, nickname: String, password: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        AZMultiplayer.shared.join(address: address, port: port, nickname: nickname,
                                  password: password) { [weak self] error in
            Task { @MainActor in
                self?.finishConnecting(error)
            }
        }
    }

    func host(name: String, port: Int, nickname: String, password: String, maxMembers: Int) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        AZMultiplayer.shared.host(name: name, port: port, nickname: nickname, password: password,
                                  maxMembers: maxMembers) { [weak self] error in
            Task { @MainActor in
                self?.finishConnecting(error)
            }
        }
    }

    private func finishConnecting(_ error: String?) {
        isWorking = false
        errorMessage = error
        refresh()
    }

    func send(_ message: String) {
        AZMultiplayer.shared.send(message: message)
    }

    func leave() {
        AZMultiplayer.shared.leave()
        refresh()
    }

    func kick(_ nickname: String) {
        AZMultiplayer.shared.kick(nickname)
    }
}
