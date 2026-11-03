// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI
import UIKit

/// On-screen 3DS controller drawn on top of the emulated screens.
struct ControllerOverlay: View {
    let opacity: Double
    let haptics: Bool

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            let unit = min(geometry.size.width, geometry.size.height) * (portrait ? 0.14 : 0.12)

            ZStack {
                // Shoulder buttons
                VStack {
                    HStack {
                        VStack(spacing: 8) {
                            PillButton(label: "ZL", button: .zl, haptics: haptics)
                            PillButton(label: "L", button: .l, haptics: haptics)
                        }
                        Spacer()
                        VStack(spacing: 8) {
                            PillButton(label: "ZR", button: .zr, haptics: haptics)
                            PillButton(label: "R", button: .r, haptics: haptics)
                        }
                    }
                    .padding(.top, portrait ? geometry.size.height * 0.52 : 56)
                    Spacer()
                }

                // Left side: circle pad and d-pad
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(spacing: unit * 0.35) {
                            CirclePad(stick: .circlePad, size: unit * 2.1)
                            DPad(size: unit * 2.1, haptics: haptics)
                        }
                        Spacer()
                        VStack(spacing: unit * 0.35) {
                            FaceButtons(size: unit * 2.2, haptics: haptics)
                            CirclePad(stick: .cStick, size: unit * 1.2)
                        }
                    }
                }

                // Center: start / select / home
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        SmallButton(systemImage: "minus", button: .select, haptics: haptics)
                        SmallButton(systemImage: "house.fill", button: .home, haptics: haptics)
                        SmallButton(systemImage: "plus", button: .start, haptics: haptics)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .opacity(opacity)
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Button primitives

/// Tracks press/release of a 3DS button with a zero distance drag gesture, which supports
/// pressing several buttons at once with multiple fingers.
private struct PressGesture: ViewModifier {
    let button: ConsoleButton
    let haptics: Bool
    @Binding var pressed: Bool

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        button.set(true)
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }
                .onEnded { _ in
                    pressed = false
                    button.set(false)
                }
        )
    }
}

private struct RoundButton: View {
    let label: String
    let button: ConsoleButton
    let size: CGFloat
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        Circle()
            .fill(pressed ? Color.white.opacity(0.55) : Color.white.opacity(0.22))
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
            .overlay(
                Text(label)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(PressGesture(button: button, haptics: haptics, pressed: $pressed))
            .accessibilityLabel(label)
    }
}

private struct PillButton: View {
    let label: String
    let button: ConsoleButton
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 64, height: 32)
            .background(
                Capsule().fill(pressed ? Color.white.opacity(0.55) : Color.white.opacity(0.22)))
            .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
            .contentShape(Capsule())
            .modifier(PressGesture(button: button, haptics: haptics, pressed: $pressed))
            .accessibilityLabel(label)
    }
}

private struct SmallButton: View {
    let systemImage: String
    let button: ConsoleButton
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 26)
            .background(
                Capsule().fill(pressed ? Color.white.opacity(0.55) : Color.white.opacity(0.22)))
            .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            .modifier(PressGesture(button: button, haptics: haptics, pressed: $pressed))
    }
}

private struct FaceButtons: View {
    let size: CGFloat
    let haptics: Bool

    var body: some View {
        let button = size * 0.36
        ZStack {
            RoundButton(label: "X", button: .x, size: button, haptics: haptics)
                .offset(y: -size * 0.32)
            RoundButton(label: "B", button: .b, size: button, haptics: haptics)
                .offset(y: size * 0.32)
            RoundButton(label: "Y", button: .y, size: button, haptics: haptics)
                .offset(x: -size * 0.32)
            RoundButton(label: "A", button: .a, size: button, haptics: haptics)
                .offset(x: size * 0.32)
        }
        .frame(width: size, height: size)
    }
}

/// D-pad that supports sliding between directions (including diagonals).
private struct DPad: View {
    let size: CGFloat
    let haptics: Bool
    @State private var active: Set<ConsoleButton> = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.22))
                .frame(width: size * 0.34, height: size)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.22))
                .frame(width: size, height: size * 0.34)
            ForEach([ConsoleButton.up, .down, .left, .right], id: \.self) { direction in
                Image(systemName: arrow(for: direction))
                    .font(.system(size: size * 0.16, weight: .bold))
                    .foregroundStyle(Color.white.opacity(active.contains(direction) ? 1.0 : 0.7))
                    .offset(offset(for: direction))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in update(location: value.location) }
                .onEnded { _ in update(directions: []) }
        )
    }

    private func arrow(for direction: ConsoleButton) -> String {
        switch direction {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case .left: return "arrowtriangle.left.fill"
        default: return "arrowtriangle.right.fill"
        }
    }

    private func offset(for direction: ConsoleButton) -> CGSize {
        let distance = size * 0.33
        switch direction {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        default: return CGSize(width: distance, height: 0)
        }
    }

    private func update(location: CGPoint) {
        let dx = location.x - size / 2
        let dy = location.y - size / 2
        let deadzone = size * 0.12
        var directions: Set<ConsoleButton> = []
        if dx < -deadzone { directions.insert(.left) }
        if dx > deadzone { directions.insert(.right) }
        if dy < -deadzone { directions.insert(.up) }
        if dy > deadzone { directions.insert(.down) }
        update(directions: directions)
    }

    private func update(directions: Set<ConsoleButton>) {
        guard directions != active else { return }
        for released in active.subtracting(directions) {
            released.set(false)
        }
        for pressed in directions.subtracting(active) {
            pressed.set(true)
        }
        if haptics && !directions.subtracting(active).isEmpty {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        active = directions
    }
}

/// Analog stick used for the circle pad and the C-stick.
private struct CirclePad: View {
    let stick: ConsoleStick
    let size: CGFloat
    @State private var knob: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.15))
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            Circle()
                .fill(Color.white.opacity(0.45))
                .frame(width: size * 0.5, height: size * 0.5)
                .offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let radius = size / 2
                    var dx = value.location.x - radius
                    var dy = value.location.y - radius
                    let length = sqrt(dx * dx + dy * dy)
                    if length > radius {
                        dx = dx / length * radius
                        dy = dy / length * radius
                    }
                    knob = CGSize(width: dx, height: dy)
                    stick.set(x: Float(dx / radius), y: Float(-dy / radius))
                }
                .onEnded { _ in
                    knob = .zero
                    stick.set(x: 0, y: 0)
                }
        )
    }
}
