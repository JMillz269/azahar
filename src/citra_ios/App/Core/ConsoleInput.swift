// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import CoreMotion
import GameController
import UIKit

/// 3DS buttons, raw values match AZButton / Settings::NativeButton.
enum ConsoleButton: Int, CaseIterable {
    case a = 0, b, x, y, up, down, left, right, l, r, start, select, debug, gpio14, zl, zr, home

    var core: AZButton { AZButton(rawValue: rawValue)! }

    func set(_ pressed: Bool) {
        AZEmulator.shared.setButton(core, pressed: pressed)
    }
}

enum ConsoleStick: Int {
    case circlePad = 0
    case cStick = 1

    /// Values in [-1, 1], +y is up.
    func set(x: Float, y: Float) {
        AZEmulator.shared.setAnalog(AZAnalog(rawValue: rawValue)!, x: x, y: y)
    }
}

/// A button of a physical controller, by position (south is A on an Xbox pad, Cross on a
/// PlayStation pad).
enum PhysicalInput: String, CaseIterable, Codable, Identifiable {
    case south, east, west, north
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options, home
    case leftStickButton, rightStickButton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .south: return "South Button"
        case .east: return "East Button"
        case .west: return "West Button"
        case .north: return "North Button"
        case .leftShoulder: return "Left Shoulder"
        case .rightShoulder: return "Right Shoulder"
        case .leftTrigger: return "Left Trigger"
        case .rightTrigger: return "Right Trigger"
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .menu: return "Menu"
        case .options: return "Options"
        case .home: return "Home"
        case .leftStickButton: return "Left Stick Click"
        case .rightStickButton: return "Right Stick Click"
        }
    }

    func isPressed(on pad: GCExtendedGamepad) -> Bool {
        switch self {
        case .south: return pad.buttonA.isPressed
        case .east: return pad.buttonB.isPressed
        case .west: return pad.buttonX.isPressed
        case .north: return pad.buttonY.isPressed
        case .leftShoulder: return pad.leftShoulder.isPressed
        case .rightShoulder: return pad.rightShoulder.isPressed
        case .leftTrigger: return pad.leftTrigger.isPressed
        case .rightTrigger: return pad.rightTrigger.isPressed
        case .dpadUp: return pad.dpad.up.isPressed
        case .dpadDown: return pad.dpad.down.isPressed
        case .dpadLeft: return pad.dpad.left.isPressed
        case .dpadRight: return pad.dpad.right.isPressed
        case .menu: return pad.buttonMenu.isPressed
        case .options: return pad.buttonOptions?.isPressed ?? false
        case .home: return pad.buttonHome?.isPressed ?? false
        case .leftStickButton: return pad.leftThumbstickButton?.isPressed ?? false
        case .rightStickButton: return pad.rightThumbstickButton?.isPressed ?? false
        }
    }
}

/// Things a controller button can do besides playing the game.
enum Hotkey: String, CaseIterable, Codable, Identifiable {
    case menu
    case fastForward
    case screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: return "Open Menu"
        case .fastForward: return "Fast Forward"
        case .screenshot: return "Take Screenshot"
        }
    }
}

extension ConsoleButton {
    /// The buttons that can be remapped, in the order they are listed.
    static let remappable: [ConsoleButton] = [
        .a, .b, .x, .y, .l, .r, .zl, .zr, .start, .select, .home, .up, .down, .left, .right,
    ]

    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .start: return "Start"
        case .select: return "Select"
        case .home: return "Home"
        case .up: return "D-Pad Up"
        case .down: return "D-Pad Down"
        case .left: return "D-Pad Left"
        case .right: return "D-Pad Right"
        default: return "Button \(rawValue)"
        }
    }
}

/// Which sticks drive the 3DS sticks.
enum StickSource: String, CaseIterable, Codable, Identifiable {
    case left, right, none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "Left Stick"
        case .right: return "Right Stick"
        case .none: return "Not Used"
        }
    }
}

/// How a physical controller maps to the 3DS. The default is the layout of a Nintendo console:
/// east is A, south is B, north is X and west is Y.
struct ControllerMapping: Codable, Equatable {
    var buttons: [String: PhysicalInput] = ControllerMapping.defaultButtons
    var circlePad = StickSource.left
    var cStick = StickSource.right
    var hotkeys: [String: PhysicalInput] = [:]

    static let defaultButtons: [String: PhysicalInput] = [
        "a": .east, "b": .south, "x": .north, "y": .west,
        "l": .leftShoulder, "r": .rightShoulder, "zl": .leftTrigger, "zr": .rightTrigger,
        "start": .menu, "select": .options, "home": .home,
        "up": .dpadUp, "down": .dpadDown, "left": .dpadLeft, "right": .dpadRight,
    ]

    static func key(_ button: ConsoleButton) -> String {
        "\(button)"
    }

    func input(for button: ConsoleButton) -> PhysicalInput? {
        buttons[Self.key(button)]
    }

    /// Gives a button a controller input. A button that had that input gets the one this button
    /// had, so two buttons can be swapped; a hotkey on it is taken off.
    mutating func assign(_ input: PhysicalInput, to button: ConsoleButton) {
        let key = Self.key(button)
        let previous = buttons[key]
        for (other, value) in buttons where value == input && other != key {
            if let previous {
                buttons[other] = previous
            } else {
                buttons[other] = nil
            }
        }
        for (hotkey, value) in hotkeys where value == input {
            hotkeys[hotkey] = nil
        }
        buttons[key] = input
    }

    /// Gives a hotkey a controller input, taking it from the hotkey or button that had it.
    mutating func assign(_ input: PhysicalInput, to hotkey: Hotkey) {
        for (other, value) in hotkeys where value == input {
            hotkeys[other] = nil
        }
        for (button, value) in buttons where value == input {
            buttons[button] = nil
        }
        hotkeys[hotkey.rawValue] = input
    }

    // The mapping the controller handler reads, which runs on another thread than the settings.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage = ControllerMappingStore.load()

    static var current: ControllerMapping {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// The saved mapping, shared with the settings screen.
@MainActor
final class ControllerMappingStore: ObservableObject {
    nonisolated private static let key = "controllerMapping.v1"

    @Published var mapping: ControllerMapping {
        didSet {
            ControllerMapping.current = mapping
            if let data = try? JSONEncoder().encode(mapping) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        mapping = ControllerMappingStore.load()
    }

    nonisolated static func load() -> ControllerMapping {
        guard let data = UserDefaults.standard.data(forKey: key),
              let mapping = try? JSONDecoder().decode(ControllerMapping.self, from: data)
        else { return ControllerMapping() }
        return mapping
    }

    func reset() {
        mapping = ControllerMapping()
    }
}

/// Maps MFi / Xbox / PlayStation / Switch controllers to the 3DS controls, following the
/// mapping the user set (see `ControllerMapping`).
final class GameControllerInput {
    private var observers: [NSObjectProtocol] = []
    private var hotkeyState: [Hotkey: Bool] = [:]

    /// Called on the main thread with whether a physical controller is connected, when that
    /// changes and when the input starts.
    var onConnectionChange: ((Bool) -> Void)?
    /// Called when a button with a hotkey goes down.
    var onHotkey: ((Hotkey) -> Void)?

    private func reportConnection() {
        onConnectionChange?(GCController.controllers().contains { $0.extendedGamepad != nil })
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            // The controller is still listed while the notification is delivered on some
            // versions, so look again once it has been removed.
            DispatchQueue.main.async { self?.reportConnection() }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.attach(controller)
            }
            self?.reportConnection()
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
        reportConnection()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        onConnectionChange?(false)
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            let mapping = ControllerMapping.current
            for button in ConsoleButton.remappable {
                let pressed = mapping.input(for: button)?.isPressed(on: gamepad) ?? false
                button.set(pressed)
            }
            for (name, input) in mapping.hotkeys {
                guard let hotkey = Hotkey(rawValue: name) else { continue }
                let pressed = input.isPressed(on: gamepad)
                if pressed && self?.hotkeyState[hotkey] != true {
                    self?.onHotkey?(hotkey)
                }
                self?.hotkeyState[hotkey] = pressed
            }
            let stick = { (source: StickSource) -> (Float, Float) in
                switch source {
                case .left: return (gamepad.leftThumbstick.xAxis.value,
                                    gamepad.leftThumbstick.yAxis.value)
                case .right: return (gamepad.rightThumbstick.xAxis.value,
                                     gamepad.rightThumbstick.yAxis.value)
                case .none: return (0, 0)
                }
            }
            let circle = stick(mapping.circlePad)
            ConsoleStick.circlePad.set(x: circle.0, y: circle.1)
            let c = stick(mapping.cStick)
            ConsoleStick.cStick.set(x: c.0, y: c.1)
        }
    }
}

/// Feeds the device accelerometer and gyroscope to the emulated 3DS motion sensors.
final class MotionInput {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let motion else { return }
            let accel = CMAcceleration(
                x: motion.gravity.x + motion.userAcceleration.x,
                y: motion.gravity.y + motion.userAcceleration.y,
                z: motion.gravity.z + motion.userAcceleration.z)
            let gyro = motion.rotationRate
            let degrees = 180.0 / Double.pi

            // Device axes are reported in portrait orientation, rotate them for landscape so
            // they match the way the 3DS is held.
            var ax = accel.x, ay = accel.y
            var gx = gyro.x, gy = gyro.y
            switch MotionInput.orientation {
            case .landscapeLeft:
                (ax, ay) = (-accel.y, accel.x)
                (gx, gy) = (-gyro.y, gyro.x)
            case .landscapeRight:
                (ax, ay) = (accel.y, -accel.x)
                (gx, gy) = (gyro.y, -gyro.x)
            case .portraitUpsideDown:
                (ax, ay) = (-accel.x, -accel.y)
                (gx, gy) = (-gyro.x, -gyro.y)
            default:
                break
            }
            AZEmulator.shared.setMotion(
                accelX: Float(ax), accelY: Float(ay), accelZ: Float(accel.z),
                gyroX: Float(gx * degrees), gyroY: Float(gy * degrees),
                gyroZ: Float(gyro.z * degrees))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Interface orientation, updated from the main thread by the emulation view.
    static var orientation: UIInterfaceOrientation = .portrait
}
