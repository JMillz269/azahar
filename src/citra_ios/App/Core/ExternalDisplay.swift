// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import QuartzCore
import SwiftUI
import UIKit

/// The view shown on an external display (AirPlay, HDMI). It is backed by a CAMetalLayer the
/// emulator renders the top screen into while a game runs.
final class ExternalDisplayView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let idleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.isOpaque = true
        idleLabel.text = "Azahar"
        idleLabel.textColor = UIColor(white: 1, alpha: 0.35)
        idleLabel.font = .systemFont(ofSize: 40, weight: .semibold)
        idleLabel.textAlignment = .center
        addSubview(idleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The idle label is hidden while the emulator draws into the layer.
    func setIdleVisible(_ visible: Bool) {
        idleLabel.isHidden = !visible
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        idleLabel.frame = bounds
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        AZEmulator.shared.setSecondaryRenderLayer(metalLayer, size: size)
    }

    func detach() {
        AZEmulator.shared.setSecondaryRenderLayer(nil, size: .zero)
    }
}

/// Scene of an external display. The system asks for it when a display is connected, as declared
/// in Info.plist. The host the app runs in has to honor external display scenes for it to appear.
@objc(ExternalSceneDelegate)
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var displayView: ExternalDisplayView?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let view = ExternalDisplayView(frame: windowScene.coordinateSpace.bounds)
        let controller = UIViewController()
        controller.view = view
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        displayView = view
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        displayView?.detach()
        displayView = nil
        window = nil
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External",
                                                     sessionRole: connectingSceneSession.role)
            configuration.delegateClass = ExternalSceneDelegate.self
            return configuration
        }
        // No delegate class here: SwiftUI forwards the scene to the class a configuration
        // names, and the session's own configuration names SwiftUI's scene delegate, so
        // returning it made that delegate forward to itself until the stack overflowed.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
