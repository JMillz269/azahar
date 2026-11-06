// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// The two screens of the custom layout.
private enum EditedScreen: Int, CaseIterable, Identifiable {
    case top = 0
    case bottom = 1

    var id: Int { rawValue }

    var title: String {
        self == .top ? "Top Screen" : "Bottom Screen"
    }

    /// Width over height of the screen.
    var aspect: CGFloat {
        self == .top ? 400.0 / 240.0 : 320.0 / 240.0
    }

    /// Index of its x fraction in the eight saved values.
    var offset: Int { rawValue * 4 }

    var other: EditedScreen { self == .top ? .bottom : .top }
}

/// Moves and resizes the two screens of the custom layout over the running game. Positions are
/// kept as fractions of the game view, separately for portrait and landscape.
///
/// A screen is moved by dragging it and resized with the slider. The screens stay inside the view
/// and never overlap: their edges snap to the edges of the view and of the other screen when they
/// come close, and a screen pushed into the other one stops against it.
struct ScreenLayoutEditor: View {
    @Binding var isEditing: Bool
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: EmulationSession

    @State private var selected = EditedScreen.top
    @State private var dragStart: CGRect?
    @State private var panelAtBottom = false

    /// How close (in points) an edge has to come to another one to snap to it.
    private static let snapDistance: CGFloat = 14
    /// Smallest size, as a fraction of the largest size a screen can have.
    private static let minimumSize: Double = 0.15

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let portrait = size.height > size.width
            let frames = currentFrames(size: size, portrait: portrait)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)

                ForEach(EditedScreen.allCases) { screen in
                    screenView(screen, frame: frames[screen.rawValue],
                               frames: frames, size: size, portrait: portrait)
                }

                VStack {
                    if panelAtBottom { Spacer() }
                    panel(frames: frames, size: size, portrait: portrait)
                    if !panelAtBottom { Spacer() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Views

    private func screenView(_ screen: EditedScreen, frame: CGRect, frames: [CGRect], size: CGSize,
                            portrait: Bool) -> some View {
        let isSelected = screen == selected
        return RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 4 : 2)
            .background(Color.accentColor.opacity(isSelected ? 0.28 : 0.14),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(Text(screen.title).font(.headline).foregroundStyle(.white))
            .frame(width: max(frame.width, 24), height: max(frame.height, 24))
            .contentShape(Rectangle())
            .position(x: frame.midX, y: frame.midY)
            .onTapGesture { selected = screen }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = frame
                            selected = screen
                        }
                        guard let start = dragStart else { return }
                        let moved = start.offsetBy(dx: value.translation.width,
                                                   dy: value.translation.height)
                        let other = frames[screen.other.rawValue]
                        if let placed = place(moved, avoiding: other, in: size, snap: true,
                                              wasOverlapping: start.intersects(other)) {
                            store(placed, for: screen, size: size, portrait: portrait)
                        }
                    }
                    .onEnded { _ in dragStart = nil })
    }

    private func panel(frames: [CGRect], size: CGSize, portrait: Bool) -> some View {
        let frame = frames[selected.rawValue]
        let maxWidth = largestWidth(of: selected, in: size)
        return VStack(spacing: 10) {
            Picker("Screen", selection: $selected) {
                ForEach(EditedScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                Slider(
                    value: Binding(
                        get: { Double(frame.width / maxWidth) },
                        set: { resize(selected, to: $0, frames: frames, size: size,
                                      portrait: portrait) }),
                    in: Self.minimumSize...1.0)
                Image(systemName: "plus.magnifyingglass")
                Text("\(Int((frame.width / maxWidth * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }

            Text("Drag a screen to move it. Screens snap to the edges and to each other.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Reset") { reset(portrait) }
                Spacer()
                Button {
                    panelAtBottom.toggle()
                } label: {
                    Image(systemName: panelAtBottom ? "arrow.up.to.line" : "arrow.down.to.line")
                }
                .accessibilityLabel(panelAtBottom ? "Move panel to the top"
                                                  : "Move panel to the bottom")
                Button("Done") { isEditing = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(8)
    }

    // MARK: Geometry

    /// The largest width a screen can have and still fit in the view.
    private func largestWidth(of screen: EditedScreen, in size: CGSize) -> CGFloat {
        max(1, min(size.width, size.height * screen.aspect))
    }

    /// Resizes a screen around its middle, then keeps it in the view and off the other screen. A
    /// size that cannot fit next to the other screen is ignored, so the slider stops there.
    private func resize(_ screen: EditedScreen, to fraction: Double, frames: [CGRect],
                        size: CGSize, portrait: Bool) {
        let current = frames[screen.rawValue]
        let width = largestWidth(of: screen, in: size) * CGFloat(fraction)
        let height = width / screen.aspect
        let resized = CGRect(x: current.midX - width / 2, y: current.midY - height / 2,
                             width: width, height: height)
        let other = frames[screen.other.rawValue]
        if let placed = place(resized, avoiding: other, in: size, snap: false,
                              wasOverlapping: current.intersects(other)) {
            store(placed, for: screen, size: size, portrait: portrait)
        }
    }

    /// Snaps `rect` to the nearby edges, keeps it inside the view and moves it out of `other`.
    /// Returns nil when it cannot be placed without overlapping. A screen that already overlapped
    /// (a layout saved before the screens avoided each other) moves freely until it is apart.
    private func place(_ rect: CGRect, avoiding other: CGRect, in size: CGSize, snap: Bool,
                       wasOverlapping: Bool) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: size)
        var result = rect
        if snap {
            result = snapped(result, to: other, in: size)
        }
        result = inside(result, bounds)

        if wasOverlapping || !result.intersects(other) { return result }

        // Push out along the direction that needs the least movement and stays in the view.
        let candidates = [
            result.offsetBy(dx: other.minX - result.maxX, dy: 0), // to the left of other
            result.offsetBy(dx: other.maxX - result.minX, dy: 0), // to the right of other
            result.offsetBy(dx: 0, dy: other.minY - result.maxY), // above other
            result.offsetBy(dx: 0, dy: other.maxY - result.minY), // below other
        ]
        let valid = candidates.filter { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }
        return valid.min { distance($0, result) < distance($1, result) }
    }

    /// Moves the rectangle so an edge lines up with a close edge of the view or of `other`.
    private func snapped(_ rect: CGRect, to other: CGRect, in size: CGSize) -> CGRect {
        let xTargets = [0, size.width, other.minX, other.maxX, size.width / 2]
        let yTargets = [0, size.height, other.minY, other.maxY, size.height / 2]
        let dx = closestOffset(edges: [rect.minX, rect.maxX, rect.midX], targets: xTargets)
        let dy = closestOffset(edges: [rect.minY, rect.maxY, rect.midY], targets: yTargets)
        return rect.offsetBy(dx: dx, dy: dy)
    }

    private func closestOffset(edges: [CGFloat], targets: [CGFloat]) -> CGFloat {
        var best: CGFloat = 0
        var bestDistance = Self.snapDistance
        for edge in edges {
            for target in targets where abs(target - edge) < bestDistance {
                bestDistance = abs(target - edge)
                best = target - edge
            }
        }
        return best
    }

    private func inside(_ rect: CGRect, _ bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        result.origin.y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
        return result
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY)
    }

    // MARK: Storage

    /// The two screens in points: the saved fractions or the default layout.
    private func currentFrames(size: CGSize, portrait: Bool) -> [CGRect] {
        let fractions = currentFractions(size: size, portrait: portrait)
        return EditedScreen.allCases.map { screen in
            let index = screen.offset
            return CGRect(x: fractions[index] * size.width, y: fractions[index + 1] * size.height,
                          width: fractions[index + 2] * size.width,
                          height: fractions[index + 3] * size.height)
        }
    }

    private func currentFractions(size: CGSize, portrait: Bool) -> [Double] {
        let saved = portrait ? settings.customLayoutPortrait : settings.customLayoutLandscape
        if saved.count == 8 { return saved }
        return AZEmulator.defaultCustomLayout(size: size, portrait: portrait).map(\.doubleValue)
    }

    private func store(_ frame: CGRect, for screen: EditedScreen, size: CGSize, portrait: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        var fractions = currentFractions(size: size, portrait: portrait)
        let index = screen.offset
        fractions[index] = Double(frame.minX / size.width)
        fractions[index + 1] = Double(frame.minY / size.height)
        fractions[index + 2] = Double(frame.width / size.width)
        fractions[index + 3] = Double(frame.height / size.height)
        if portrait {
            settings.customLayoutPortrait = fractions
        } else {
            settings.customLayoutLandscape = fractions
        }
        session.apply(settings: settings)
        AZEmulator.shared.refreshLayout()
    }

    private func reset(_ portrait: Bool) {
        if portrait {
            settings.customLayoutPortrait = []
        } else {
            settings.customLayoutLandscape = []
        }
        session.apply(settings: settings)
        AZEmulator.shared.refreshLayout()
    }
}
