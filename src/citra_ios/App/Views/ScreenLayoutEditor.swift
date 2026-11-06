// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import SwiftUI

/// Moves and resizes the two screens of the custom layout over the running game. Positions are
/// kept as fractions of the game view, separately for portrait and landscape.
struct ScreenLayoutEditor: View {
    @Binding var isEditing: Bool
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: EmulationSession

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let portrait = size.height > size.width
            let rects = currentRects(size: size, portrait: portrait)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)

                ScreenRect(title: "Top Screen", aspect: 400.0 / 240.0, containerSize: size,
                           fraction: Array(rects[0..<4])) { update(0, $0, portrait, size) }
                ScreenRect(title: "Bottom Screen", aspect: 320.0 / 240.0, containerSize: size,
                           fraction: Array(rects[4..<8])) { update(4, $0, portrait, size) }

                VStack {
                    HStack(spacing: 12) {
                        Text("Drag a screen to move it, pinch to resize.")
                            .font(.callout)
                        Spacer()
                        Button("Reset") { reset(portrait) }
                        Button("Done") { isEditing = false }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    Spacer()
                }
            }
        }
    }

    /// The eight fractions in use: the saved ones or the default.
    private func currentRects(size: CGSize, portrait: Bool) -> [Double] {
        let saved = portrait ? settings.customLayoutPortrait : settings.customLayoutLandscape
        if saved.count == 8 { return saved }
        return AZEmulator.defaultCustomLayout(size: size, portrait: portrait).map(\.doubleValue)
    }

    private func update(_ offset: Int, _ fraction: [Double], _ portrait: Bool, _ size: CGSize) {
        var rects = currentRects(size: size, portrait: portrait)
        for index in 0..<4 { rects[offset + index] = fraction[index] }
        if portrait {
            settings.customLayoutPortrait = rects
        } else {
            settings.customLayoutLandscape = rects
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

/// One screen of the editor: a draggable, pinchable rectangle with the aspect ratio of the screen.
private struct ScreenRect: View {
    let title: String
    let aspect: Double
    let containerSize: CGSize
    /// x, y, width and height as fractions of the container.
    let fraction: [Double]
    let onChange: ([Double]) -> Void

    @State private var dragStart: [Double]?
    @State private var pinchStart: [Double]?

    var body: some View {
        let frame = CGRect(
            x: fraction[0] * containerSize.width, y: fraction[1] * containerSize.height,
            width: fraction[2] * containerSize.width, height: fraction[3] * containerSize.height)

        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(Text(title).font(.headline).foregroundStyle(.white))
            .frame(width: max(frame.width, 24), height: max(frame.height, 24))
            .contentShape(Rectangle())
            .position(x: frame.midX, y: frame.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = fraction }
                        guard let start = dragStart else { return }
                        var next = start
                        next[0] = start[0] + Double(value.translation.width / containerSize.width)
                        next[1] = start[1] + Double(value.translation.height / containerSize.height)
                        onChange(clamped(next))
                    }
                    .onEnded { _ in dragStart = nil }
                    .simultaneously(with:
                        MagnificationGesture()
                            .onChanged { magnification in
                                if pinchStart == nil { pinchStart = fraction }
                                guard let start = pinchStart else { return }
                                // Resize around the middle, keeping the aspect ratio.
                                let width = max(0.08, min(start[2] * Double(magnification), 1.0))
                                let height = width * containerSize.width / containerSize.height
                                    / aspect
                                var next = start
                                next[0] = start[0] + (start[2] - width) / 2
                                next[1] = start[1] + (start[3] - height) / 2
                                next[2] = width
                                next[3] = height
                                onChange(clamped(next))
                            }
                            .onEnded { _ in pinchStart = nil })
            )
    }

    /// Keeps the screen mostly inside the view.
    private func clamped(_ rect: [Double]) -> [Double] {
        var result = rect
        result[0] = max(-rect[2] * 0.5, min(rect[0], 1.0 - rect[2] * 0.5))
        result[1] = max(-rect[3] * 0.5, min(rect[1], 1.0 - rect[3] * 0.5))
        return result
    }
}
