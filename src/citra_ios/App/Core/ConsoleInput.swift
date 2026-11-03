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

/// Maps MFi / Xbox / PlayStation / Switch controllers to the 3DS controls. Face buttons are
/// mapped by position (east = A, south = B, north = X, west = Y) like on a Nintendo console.
final class GameControllerInput {
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.attach(controller)
            }
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { gamepad, _ in
            ConsoleButton.a.set(gamepad.buttonB.isPressed)
            ConsoleButton.b.set(gamepad.buttonA.isPressed)
            ConsoleButton.x.set(gamepad.buttonY.isPressed)
            ConsoleButton.y.set(gamepad.buttonX.isPressed)
            ConsoleButton.l.set(gamepad.leftShoulder.isPressed)
            ConsoleButton.r.set(gamepad.rightShoulder.isPressed)
            ConsoleButton.zl.set(gamepad.leftTrigger.isPressed)
            ConsoleButton.zr.set(gamepad.rightTrigger.isPressed)
            ConsoleButton.start.set(gamepad.buttonMenu.isPressed)
            ConsoleButton.select.set(gamepad.buttonOptions?.isPressed ?? false)
            ConsoleButton.home.set(gamepad.buttonHome?.isPressed ?? false)
            ConsoleButton.up.set(gamepad.dpad.up.isPressed)
            ConsoleButton.down.set(gamepad.dpad.down.isPressed)
            ConsoleButton.left.set(gamepad.dpad.left.isPressed)
            ConsoleButton.right.set(gamepad.dpad.right.isPressed)
            ConsoleStick.circlePad.set(
                x: gamepad.leftThumbstick.xAxis.value, y: gamepad.leftThumbstick.yAxis.value)
            ConsoleStick.cStick.set(
                x: gamepad.rightThumbstick.xAxis.value, y: gamepad.rightThumbstick.yAxis.value)
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
