// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import GameController
import SwiftUI

/// What a pressed controller button is being chosen for.
private enum CaptureTarget: Equatable {
    case button(ConsoleButton)
    case hotkey(Hotkey)

    var title: String {
        switch self {
        case .button(let button): return button.title
        case .hotkey(let hotkey): return hotkey.title
        }
    }
}

/// Waits for the next press on a connected controller.
@MainActor
private final class ButtonCapture: ObservableObject {
    @Published private(set) var target: CaptureTarget?
    private var onCapture: ((PhysicalInput) -> Void)?

    var hasController: Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    func begin(_ target: CaptureTarget, onCapture: @escaping (PhysicalInput) -> Void) {
        cancel()
        self.target = target
        self.onCapture = onCapture
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
                guard let input = PhysicalInput.allCases.first(where: { $0.isPressed(on: pad) })
                else { return }
                Task { @MainActor in self?.finish(input) }
            }
        }
    }

    func cancel() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        target = nil
        onCapture = nil
    }

    private func finish(_ input: PhysicalInput) {
        guard target != nil, let onCapture else { return }
        cancel()
        onCapture(input)
    }
}

/// Chooses which button of a game controller does what: the 3DS buttons, the sticks and a few
/// extra actions.
struct ControllerMappingView: View {
    @EnvironmentObject private var store: ControllerMappingStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var capture = ButtonCapture()
    @State private var noController = false
    @State private var namingProfile = false
    @State private var renamingProfile = false
    @State private var profileName = ""

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: Binding(
                    get: { store.activeProfileID },
                    set: { store.select($0) })) {
                    Text("Unsaved Mapping").tag(String?.none)
                    ForEach(store.profiles) { Text($0.name).tag(String?.some($0.id)) }
                }
                Button("Save as New Profile…") {
                    profileName = ""
                    namingProfile = true
                }
                if let profile = store.activeProfile {
                    Button("Rename \"\(profile.name)\"…") {
                        profileName = profile.name
                        renamingProfile = true
                    }
                    Button("Delete \"\(profile.name)\"", role: .destructive) {
                        store.deleteProfile(profile.id)
                    }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Keep several mappings, for example one per controller. Changes below are "
                     + "saved into the chosen profile. A game can use its own profile in its Game "
                     + "Settings.")
            }

            Section {
                ForEach(ConsoleButton.remappable, id: \.self) { button in
                    row(title: button.title,
                        input: store.mapping.input(for: button)) {
                        listen(for: .button(button))
                    }
                }
            } header: {
                Text("3DS Buttons")
            } footer: {
                Text("Tap a button, then press the button of your controller that should do it. "
                     + "A button that was already in use swaps places.")
            }

            Section("Sticks") {
                Picker("Circle Pad", selection: $store.mapping.circlePad) {
                    ForEach(StickSource.allCases) { Text($0.title).tag($0) }
                }
                Picker("C-Stick", selection: $store.mapping.cStick) {
                    ForEach(StickSource.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("Touch Screen Cursor", selection: $settings.touchStick) {
                    Text("Off").tag(0)
                    Text("Left Stick").tag(1)
                    Text("Right Stick").tag(2)
                }
                if settings.touchStick != 0 {
                    VStack(alignment: .leading) {
                        Text(String(format: "Cursor Speed: %.1fx", settings.touchStickSpeed))
                        Slider(value: $settings.touchStickSpeed, in: 0.4...2.5, step: 0.1)
                    }
                }
            } header: {
                Text("Touch Screen")
            } footer: {
                Text("A stick of the controller moves a cursor over the bottom screen. Give a "
                     + "controller button to Touch Screen Tap in the shortcuts below to tap with "
                     + "it. The stick no longer drives the circle pad or the C-stick.")
            }

            Section {
                ForEach(Hotkey.allCases) { hotkey in
                    row(title: hotkey.title, input: store.mapping.hotkeys[hotkey.rawValue]) {
                        listen(for: .hotkey(hotkey))
                    }
                    .swipeActions {
                        Button("Clear", role: .destructive) {
                            store.mapping.hotkeys[hotkey.rawValue] = nil
                        }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("A shortcut uses a controller button instead of a 3DS button. Swipe left to "
                     + "clear one.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { store.reset() }
                    .disabled(store.mapping == ControllerMapping())
            }
        }
        .navigationTitle("Controller Mapping")
        .alert("New Profile", isPresented: $namingProfile) {
            TextField("Name", text: $profileName)
            Button("Save") { store.addProfile(named: profileName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the mapping below under this name.")
        }
        .alert("Rename Profile", isPresented: $renamingProfile) {
            TextField("Name", text: $profileName)
            Button("Rename") {
                if let id = store.activeProfileID { store.rename(id, to: profileName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { capture.cancel() }
        .alert(capture.target.map { "Press a button for \($0.title)" } ?? "",
               isPresented: Binding(get: { capture.target != nil },
                                    set: { if !$0 { capture.cancel() } })) {
            Button("Cancel", role: .cancel) { capture.cancel() }
        } message: {
            Text("Press the button on your controller.")
        }
        .alert("No Controller", isPresented: $noController) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect a game controller first.")
        }
    }

    private func row(title: String, input: PhysicalInput?, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(input?.title ?? "None").foregroundStyle(.secondary)
            }
        }
    }

    private func listen(for target: CaptureTarget) {
        guard capture.hasController else {
            noController = true
            return
        }
        capture.begin(target) { input in
            switch target {
            case .button(let button): store.mapping.assign(input, to: button)
            case .hotkey(let hotkey): store.mapping.assign(input, to: hotkey)
            }
        }
    }
}
