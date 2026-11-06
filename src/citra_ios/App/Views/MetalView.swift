// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import QuartzCore
import SwiftUI
import UIKit

/// UIView backed by the CAMetalLayer the emulator renders into. It receives every touch on the
/// game: those on the on-screen controller go to `ControllerTouchHandler`, the others to the
/// emulated touch screen.
final class EmulatorLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Called once the layer has a non-zero size.
    var onReady: (() -> Void)?

    private weak var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var pixelScale: CGFloat {
        window?.screen.scale ?? UIScreen.main.scale
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        AZEmulator.shared.setRenderLayer(window != nil ? metalLayer : nil)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = pixelScale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        AZEmulator.shared.setDrawableSize(size, portrait: bounds.height > bounds.width)
        if let orientation = window?.windowScene?.interfaceOrientation {
            MotionInput.orientation = orientation
            AZEmulator.setCameraOrientationLandscapeLeft(orientation == .landscapeLeft)
        }
        onReady?()
    }

    private func pixelLocation(of touch: UITouch) -> CGPoint {
        let point = touch.location(in: self)
        let scale = pixelScale
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    // Touches on the on-screen controller go to its handler, the rest drive the 3DS touch screen
    // (one finger at a time).

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let unclaimed = ControllerTouchHandler.shared.began(touches)
        guard activeTouch == nil, let touch = unclaimed.first else { return }
        activeTouch = touch
        AZEmulator.shared.touchBegan(at: pixelLocation(of: touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        ControllerTouchHandler.shared.moved(touches)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        AZEmulator.shared.touchMoved(to: pixelLocation(of: touch))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        ControllerTouchHandler.shared.ended(touches)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        AZEmulator.shared.touchEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

struct MetalView: UIViewRepresentable {
    var onReady: () -> Void

    func makeUIView(context: Context) -> EmulatorLayerView {
        let view = EmulatorLayerView(frame: .zero)
        view.onReady = onReady
        return view
    }

    func updateUIView(_ view: EmulatorLayerView, context: Context) {
        view.onReady = onReady
    }

    static func dismantleUIView(_ view: EmulatorLayerView, coordinator: ()) {
        view.onReady = nil
    }
}
