// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI
import UIKit

/// Sizes and default positions of the controls for a given screen size.
private struct ControllerMetrics {
    let size: CGSize

    private let edge: CGFloat = 16
    private let bottom: CGFloat = 12

    var portrait: Bool { size.height > size.width }
    var unit: CGFloat { min(size.width, size.height) * (portrait ? 0.14 : 0.12) }

    func baseSize(of id: ControlID) -> CGSize {
        switch id {
        case .shoulderLeft, .shoulderRight: return CGSize(width: 64, height: 72)
        case .circlePad, .dpad: return CGSize(width: unit * 2.1, height: unit * 2.1)
        case .faceButtons: return CGSize(width: unit * 2.2, height: unit * 2.2)
        case .cStick: return CGSize(width: unit * 1.2, height: unit * 1.2)
        case .systemButtons: return CGSize(width: 152, height: 26)
        }
    }

    func defaultCenter(of id: ControlID) -> CGPoint {
        let shoulderTop: CGFloat = portrait ? size.height * 0.52 : 56
        switch id {
        case .shoulderLeft: return CGPoint(x: edge + 32, y: shoulderTop + 36)
        case .shoulderRight: return CGPoint(x: size.width - edge - 32, y: shoulderTop + 36)
        case .dpad:
            return CGPoint(x: edge + unit * 1.05, y: size.height - bottom - unit * 1.05)
        case .circlePad:
            return CGPoint(x: edge + unit * 1.05, y: size.height - bottom - unit * 3.5)
        case .faceButtons:
            return CGPoint(x: size.width - edge - unit * 1.1, y: size.height - bottom - unit * 2.65)
        case .cStick:
            return CGPoint(x: size.width - edge - unit * 1.1, y: size.height - bottom - unit * 0.6)
        case .systemButtons:
            return CGPoint(x: size.width / 2, y: size.height - bottom - 17)
        }
    }

    /// The frame of a control, kept fully on screen.
    func frame(of id: ControlID, placement: ControlPlacement) -> CGRect {
        let base = baseSize(of: id)
        let scale = CGFloat(placement.scale)
        let width = base.width * scale
        let height = base.height * scale
        let center = defaultCenter(of: id)
        let x = max(width / 2, min(center.x + CGFloat(placement.dx) * size.width,
                                   size.width - width / 2))
        let y = max(height / 2, min(center.y + CGFloat(placement.dy) * size.height,
                                    size.height - height / 2))
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// The placement with the offset corrected for what is actually possible on screen, so
    /// dragging past an edge does not build up an offset that is not visible.
    func clamped(_ placement: ControlPlacement, of id: ControlID) -> ControlPlacement {
        let frame = frame(of: id, placement: placement)
        let center = defaultCenter(of: id)
        var result = placement
        result.dx = Double((frame.midX - center.x) / size.width)
        result.dy = Double((frame.midY - center.y) / size.height)
        return result
    }
}

/// On-screen 3DS controller drawn on top of the emulated screens. Every part can be moved and
/// resized in the layout editor (`isEditing`).
struct ControllerOverlay: View {
    let opacity: Double
    let haptics: Bool
    @Binding var isEditing: Bool

    @EnvironmentObject private var layout: ControllerLayoutStore
    @State private var selected: ControlID?

    var body: some View {
        GeometryReader { geometry in
            let metrics = ControllerMetrics(size: geometry.size)
            let portrait = metrics.portrait

            ZStack {
                if isEditing {
                    // Dims the game and keeps touches away from it while editing.
                    Color.black.opacity(0.4)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = nil }
                }

                ZStack {
                    ForEach(ControlID.allCases) { id in
                        let placement = layout.placement(for: id, portrait: portrait)
                        let frame = metrics.frame(of: id, placement: placement)
                        content(of: id, scale: CGFloat(placement.scale), unit: metrics.unit)
                            .frame(width: frame.width, height: frame.height)
                            .allowsHitTesting(!isEditing)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .opacity(isEditing ? 1 : opacity)

                if isEditing {
                    ForEach(ControlID.allCases) { id in
                        EditHandle(id: id, metrics: metrics, isSelected: selected == id) {
                            selected = id
                        }
                    }
                    editorPanel(portrait: portrait)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: isEditing) { editing in
            if !editing { selected = nil }
        }
    }

    @ViewBuilder
    private func content(of id: ControlID, scale: CGFloat, unit: CGFloat) -> some View {
        switch id {
        case .shoulderLeft:
            VStack(spacing: 8 * scale) {
                PillButton(label: "ZL", button: .zl, scale: scale, haptics: haptics)
                PillButton(label: "L", button: .l, scale: scale, haptics: haptics)
            }
        case .shoulderRight:
            VStack(spacing: 8 * scale) {
                PillButton(label: "ZR", button: .zr, scale: scale, haptics: haptics)
                PillButton(label: "R", button: .r, scale: scale, haptics: haptics)
            }
        case .circlePad:
            CirclePad(stick: .circlePad, size: unit * 2.1 * scale)
        case .dpad:
            DPad(size: unit * 2.1 * scale, haptics: haptics)
        case .faceButtons:
            FaceButtons(size: unit * 2.2 * scale, haptics: haptics)
        case .cStick:
            CirclePad(stick: .cStick, size: unit * 1.2 * scale)
        case .systemButtons:
            HStack(spacing: 16 * scale) {
                SmallButton(systemImage: "minus", button: .select, scale: scale, haptics: haptics)
                SmallButton(systemImage: "house.fill", button: .home, scale: scale,
                            haptics: haptics)
                SmallButton(systemImage: "plus", button: .start, scale: scale, haptics: haptics)
            }
        }
    }

    // MARK: Editor

    private func editorPanel(portrait: Bool) -> some View {
        VStack {
            VStack(spacing: 10) {
                if let selected {
                    let placement = layout.placement(for: selected, portrait: portrait)
                    Text(selected.title)
                        .font(.headline)
                    HStack(spacing: 10) {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(
                            value: Binding(
                                get: { placement.scale },
                                set: { newScale in
                                    layout.update(selected, portrait: portrait) {
                                        $0.scale = newScale
                                    }
                                }),
                            in: ControlPlacement.scaleRange,
                            onEditingChanged: { editing in
                                if !editing { layout.commit() }
                            })
                        Image(systemName: "plus.magnifyingglass")
                        Text("\(Int((placement.scale * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }
                } else {
                    Text("Drag a control to move it. Pinch it or pick it to resize.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Button("Reset Control") {
                        if let selected { layout.reset(selected, portrait: portrait) }
                    }
                    .disabled(selected == nil)
                    Button("Reset All", role: .destructive) {
                        layout.resetAll(portrait: portrait)
                    }
                    Spacer()
                    Button("Done") { isEditing = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .frame(maxWidth: 400)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 8)
            .padding(.horizontal, 8)
            Spacer()
        }
    }
}

/// Outline of a control in the layout editor. Dragging it moves the control, pinching resizes it.
private struct EditHandle: View {
    let id: ControlID
    let metrics: ControllerMetrics
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var layout: ControllerLayoutStore
    @State private var startPlacement: ControlPlacement?
    @State private var startScale: Double?

    var body: some View {
        let portrait = metrics.portrait
        let placement = layout.placement(for: id, portrait: portrait)
        let frame = metrics.frame(of: id, placement: placement)

        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isSelected ? Color.accentColor : Color.white.opacity(0.85),
                style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, dash: [6, 4])
            )
            .background(Color.white.opacity(isSelected ? 0.12 : 0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .frame(width: frame.width + 12, height: frame.height + 12)
            .contentShape(Rectangle())
            .position(x: frame.midX, y: frame.midY)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if startPlacement == nil {
                            startPlacement = placement
                            onSelect()
                        }
                        guard let start = startPlacement else { return }
                        layout.update(id, portrait: portrait) {
                            $0.dx = start.dx + Double(value.translation.width / metrics.size.width)
                            $0.dy = start.dy + Double(value.translation.height / metrics.size.height)
                            $0 = metrics.clamped($0, of: id)
                        }
                    }
                    .onEnded { _ in
                        startPlacement = nil
                        layout.commit()
                    }
                    .simultaneously(
                        with: MagnificationGesture()
                            .onChanged { magnification in
                                if startScale == nil {
                                    startScale = placement.scale
                                    onSelect()
                                }
                                guard let start = startScale else { return }
                                layout.update(id, portrait: portrait) {
                                    $0.scale = start * Double(magnification)
                                    $0 = metrics.clamped($0, of: id)
                                }
                            }
                            .onEnded { _ in
                                startScale = nil
                                layout.commit()
                            })
            )
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
    let scale: CGFloat
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 64 * scale, height: 32 * scale)
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
    let scale: CGFloat
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13 * scale, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40 * scale, height: 26 * scale)
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
