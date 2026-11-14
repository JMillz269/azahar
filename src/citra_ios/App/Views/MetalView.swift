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
        NotificationCenter.default.post(name: .azaharScreenTouched, object: nil)
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

/// Asks the display for a refresh rate while a game is shown. iOS follows the highest rate any
/// display link of the app asks for, so a display link that does nothing sets the rate. iOS may
/// ignore it (Low Power Mode, a host app that does not allow rates above 60 Hz).
@MainActor
final class RefreshRateController: NSObject {
    static let shared = RefreshRateController()

    private var link: CADisplayLink?

    @objc private func tick() {}

    func apply(_ option: RefreshRateOption) {
        link?.invalidate()
        link = nil
        guard option != .automatic else { return }

        let link = CADisplayLink(target: self, selector: #selector(tick))
        let rate = Float(option.rawValue)
        // 120 Hz also allows the rates in between, which iOS picks when it has to save power.
        link.preferredFrameRateRange = option == .oneTwenty
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
}

extension Notification.Name {
    /// Posted when a finger touches the game's view (used to bring back faded-out buttons).
    static let azaharScreenTouched = Notification.Name("azaharScreenTouched")
}
