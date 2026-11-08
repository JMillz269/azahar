// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Combine
import GameController
import SwiftUI
import UIKit

/// Set while a screen listens to the controller itself (assigning a button), so the navigation
/// does not react to the same presses.
enum NavigationSuspension {
    nonisolated(unsafe) static var suspended = false
}

/// A window that shows the selection frame and lets every touch through.
private final class SelectionWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private enum Direction {
    case up, down, left, right
}

/// Moves through the menus of the app with a game controller: the D-pad or left stick moves a
/// selection frame between the controls on the screen, A presses the selected control, B goes
/// back, and the shoulder buttons scroll a page.
///
/// It reads the screen the way VoiceOver does (the accessibility elements of every window), so it
/// works with every SwiftUI screen, sheet and menu without changes to them. It is off while a game
/// is running (the controller belongs to the game) and while the pause menu is closed.
@MainActor
final class ControllerNavigator {
    static let shared = ControllerNavigator()

    private var enabled = false {
        didSet { if !enabled { hideSelection() } }
    }
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    private var selectionWindow: SelectionWindow?
    private let selectionLayer = CALayer()
    private var currentFrame: CGRect?
    private var currentLabel: String?

    private var repeatTimer: Timer?
    private var heldDirection: Direction?
    private var stickDirection: Direction?

    /// Starts following the settings and the emulation: navigation works when the option is on and
    /// no game is running (or it is paused).
    func start(session: EmulationSession, settings: AppSettings) {
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest3(session.$currentGame, session.$isPaused,
                                  settings.$controllerNavigation)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] game, paused, option in
                self?.enabled = option && (game == nil || paused)
            }
            .store(in: &cancellables)

        for controller in GCController.controllers() {
            attach(controller)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in self?.attach(controller) }
            })
    }

    // MARK: Controller input

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in self?.directionChanged(Self.direction(x: x, y: y), fromStick: false) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in
                self?.directionChanged(Self.direction(x: x, y: y, threshold: 0.6), fromStick: true)
            }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.activate() } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.goBack() } }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.scrollPage(.up) } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.scrollPage(.down) } }
        }
    }

    private static func direction(x: Float, y: Float, threshold: Float = 0.5) -> Direction? {
        if abs(x) < threshold && abs(y) < threshold { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    private func directionChanged(_ direction: Direction?, fromStick: Bool) {
        if fromStick {
            stickDirection = direction
        }
        // The D-pad and the stick share one repeat; the one that is held last wins.
        guard enabled, !NavigationSuspension.suspended else {
            stopRepeat()
            return
        }
        guard let direction else {
            if fromStick || heldDirection != nil { stopRepeat() }
            return
        }
        heldDirection = direction
        move(direction)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startRepeating() }
        }
    }

    private func startRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let direction = self.heldDirection else { return }
                self.move(direction)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldDirection = nil
    }

    // MARK: Reading the screen

    private struct Item {
        let object: NSObject
        let frame: CGRect
        let label: String
        let traits: UIAccessibilityTraits

        var isAdjustable: Bool { traits.contains(.adjustable) }
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    /// The windows of the app that can hold controls, the topmost first.
    private func windows() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication && $0.activationState == .foregroundActive }
        let all = scenes.flatMap { $0.windows }.filter { window in
            !(window is SelectionWindow) && !window.isHidden && window.alpha > 0.01
                && !NSStringFromClass(type(of: window)).contains("TextEffects")
                && !NSStringFromClass(type(of: window)).contains("Keyboard")
        }
        return all.sorted { $0.windowLevel > $1.windowLevel }
    }

    /// The controls of the topmost window that has any.
    private func items() -> (window: UIWindow, items: [Item])? {
        for window in windows() {
            var objects: [NSObject] = []
            collect(window, into: &objects, depth: 0)
            let screen = window.frame
            let items: [Item] = objects.compactMap { object in
                let frame = object.accessibilityFrame
                guard frame.width > 6, frame.height > 6, frame.intersects(screen),
                      isOperable(object.accessibilityTraits)
                else { return nil }
                return Item(object: object, frame: frame,
                            label: object.accessibilityLabel ?? "",
                            traits: object.accessibilityTraits)
            }
            if !items.isEmpty { return (window, items) }
        }
        return nil
    }

    private func collect(_ object: NSObject, into result: inout [NSObject], depth: Int) {
        guard depth < 80 else { return }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.isAccessibilityElement {
            result.append(object)
            return
        }
        if let elements = object.accessibilityElements {
            for case let element as NSObject in elements {
                collect(element, into: &result, depth: depth + 1)
            }
            return
        }
        guard let view = object as? UIView else { return }
        let count = view.accessibilityElementCount()
        if count != NSNotFound && count > 0 {
            for index in 0..<count {
                if let element = view.accessibilityElement(at: index) as? NSObject {
                    collect(element, into: &result, depth: depth + 1)
                }
            }
            return
        }
        for subview in view.subviews {
            collect(subview, into: &result, depth: depth + 1)
        }
    }

    /// Controls that do something. Plain text, headings and pictures are skipped.
    private func isOperable(_ traits: UIAccessibilityTraits) -> Bool {
        if traits.contains(.notEnabled) { return false }
        let active: UIAccessibilityTraits = [.button, .link, .adjustable, .searchField, .keyboardKey]
        if !traits.isDisjoint(with: active) { return true }
        if #available(iOS 17.0, *), traits.contains(.toggleButton) { return true }
        let passive: UIAccessibilityTraits = [.staticText, .header, .image, .summaryElement]
        return traits.isDisjoint(with: passive)
    }

    // MARK: Moving

    private func move(_ direction: Direction) {
        guard enabled, !NavigationSuspension.suspended, let (window, items) = items() else { return }
        guard let current = currentItem(in: items) else {
            select(defaultItem(in: items, window: window), window: window)
            return
        }

        // A slider or stepper changes its value with left and right.
        if current.isAdjustable, direction == .left || direction == .right {
            if direction == .right {
                current.object.accessibilityIncrement()
            } else {
                current.object.accessibilityDecrement()
            }
            return
        }

        if let next = nextItem(from: current, direction: direction, in: items) {
            select(next, window: window)
            scrollIntoView(next, window: window)
        } else if direction == .up || direction == .down {
            // Nothing in that direction on the screen, the list may continue off screen.
            if scroll(direction, window: window, near: current.center, fraction: 0.7) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.selectAfterScroll(direction)
                }
            }
        }
    }

    private func selectAfterScroll(_ direction: Direction) {
        guard enabled, let (window, items) = items() else { return }
        if let current = currentItem(in: items),
           let next = nextItem(from: current, direction: direction, in: items) {
            select(next, window: window)
        }
    }

    /// The item that is the selected one, found again after the screen changed.
    private func currentItem(in items: [Item]) -> Item? {
        guard let frame = currentFrame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let candidates = items.filter { $0.label == currentLabel }
        let pool = candidates.isEmpty ? [] : candidates
        guard let match = pool.min(by: { distance($0.center, center) < distance($1.center, center) }),
              distance(match.center, center) < 80
        else { return nil }
        return match
    }

    private func nextItem(from current: Item, direction: Direction, in items: [Item]) -> Item? {
        var best: (Item, CGFloat)?
        for item in items where item.object !== current.object {
            let dx = item.center.x - current.center.x
            let dy = item.center.y - current.center.y
            let primary: CGFloat
            let secondary: CGFloat
            switch direction {
            case .down:
                guard dy > 2 else { continue }
                primary = dy; secondary = abs(dx)
            case .up:
                guard dy < -2 else { continue }
                primary = -dy; secondary = abs(dx)
            case .right:
                guard dx > 2 else { continue }
                primary = dx; secondary = abs(dy)
            case .left:
                guard dx < -2 else { continue }
                primary = -dx; secondary = abs(dy)
            }
            let score = primary + 2.5 * secondary
            if best == nil || score < best!.1 { best = (item, score) }
        }
        return best?.0
    }

    /// The first control to select on a screen: the one at the top left, skipping the buttons of
    /// the navigation bar when there are others.
    private func defaultItem(in items: [Item], window: UIWindow) -> Item {
        let barBottom = window.safeAreaInsets.top + 52
        let body = items.filter { $0.frame.minY > barBottom }
        let pool = body.isEmpty ? items : body
        return pool.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }!
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Actions

    private func activate() {
        guard enabled, !NavigationSuspension.suspended, let (window, items) = items(),
              let current = currentItem(in: items)
        else {
            if enabled, !NavigationSuspension.suspended, let (window, items) = items() {
                select(defaultItem(in: items, window: window), window: window)
            }
            return
        }
        if !current.object.accessibilityActivate() {
            tap(current, in: window)
        }
        // The screen usually changes (a page opens, a menu appears): look again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAfterAction()
        }
    }

    /// Presses the control at its activation point when it does not handle an activation itself.
    private func tap(_ item: Item, in window: UIWindow) {
        let point = window.convert(item.object.accessibilityActivationPoint,
                                   from: window.screen.coordinateSpace)
        var view = window.hitTest(point, with: nil)
        while let candidate = view {
            if let control = candidate as? UIControl {
                control.sendActions(for: .touchUpInside)
                return
            }
            view = candidate.superview
        }
    }

    /// Keeps the selection when the control is still there (a switch), otherwise starts on the
    /// new screen.
    private func refreshAfterAction() {
        guard enabled, let (window, items) = items() else {
            hideSelection()
            return
        }
        if let current = currentItem(in: items) {
            select(current, window: window)
        } else {
            select(defaultItem(in: items, window: window), window: window)
        }
    }

    private func goBack() {
        guard enabled, !NavigationSuspension.suspended else { return }
        guard let window = windows().first else { return }

        // The escape gesture of VoiceOver: a navigation controller pops, a sheet closes.
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let top, escape(in: top) {
            scheduleRefresh()
            return
        }
        // Nothing to pop: press the back button of the navigation bar.
        if let (_, items) = items() {
            let bar = items.filter { $0.frame.minY < window.safeAreaInsets.top + 52 }
            if let back = bar.min(by: { $0.frame.minX < $1.frame.minX }),
               back.frame.minX < 120 {
                if !back.object.accessibilityActivate() { tap(back, in: window) }
                scheduleRefresh()
            }
        }
    }

    /// Looks for a navigation controller (deepest first) that can go back, then the controller
    /// itself, which can close a sheet.
    private func escape(in controller: UIViewController) -> Bool {
        for child in controller.children.reversed() where escape(in: child) { return true }
        if controller is UINavigationController || controller.presentingViewController != nil {
            return controller.accessibilityPerformEscape()
                || (controller.view?.accessibilityPerformEscape() ?? false)
        }
        return false
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.currentFrame = nil
            self?.refreshAfterAction()
        }
    }

    // MARK: Scrolling

    private func scrollPage(_ direction: Direction) {
        guard enabled, !NavigationSuspension.suspended, let window = windows().first else { return }
        let origin = currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        if scroll(direction, window: window, near: origin, fraction: 0.85) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.currentFrame = nil
                self?.refreshAfterAction()
            }
        }
    }

    /// Scrolls the list around `point` (or the biggest one) a part of its height. Returns false
    /// when it is at its end.
    @discardableResult
    private func scroll(_ direction: Direction, window: UIWindow, near point: CGPoint?,
                        fraction: CGFloat) -> Bool {
        guard let scrollView = scrollView(in: window, near: point) else { return false }
        let page = scrollView.bounds.height * fraction
        let inset = scrollView.adjustedContentInset
        let minOffset = -inset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height
                            + inset.bottom)
        var offset = scrollView.contentOffset
        let target = direction == .down ? offset.y + page : offset.y - page
        offset.y = min(max(target, minOffset), maxOffset)
        guard abs(offset.y - scrollView.contentOffset.y) > 1 else { return false }
        scrollView.setContentOffset(offset, animated: true)
        return true
    }

    private func scrollView(in window: UIWindow, near point: CGPoint?) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if view.isHidden { return }
            if let scroll = view as? UIScrollView,
               scroll.contentSize.height > scroll.bounds.height + 1,
               scroll.bounds.height > 100 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        if let point {
            let local = window.convert(point, from: window.screen.coordinateSpace)
            let containing = found.filter {
                $0.convert($0.bounds, to: window).contains(local)
            }
            if let inner = containing.last { return inner }
        }
        return found.max { $0.bounds.height < $1.bounds.height }
    }

    /// Scrolls so the whole control is visible.
    private func scrollIntoView(_ item: Item, window: UIWindow) {
        guard let scroll = scrollView(in: window, near: item.center) else { return }
        let inWindow = window.convert(item.frame, from: window.screen.coordinateSpace)
        let rect = scroll.convert(inWindow, from: window)
        scroll.scrollRectToVisible(rect.insetBy(dx: 0, dy: -28), animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.enabled, let (window, items) = self.items(),
                  let current = self.currentItem(in: items) else { return }
            self.select(current, window: window)
        }
    }

    // MARK: Selection frame

    private func select(_ item: Item, window: UIWindow) {
        currentFrame = item.frame
        currentLabel = item.label
        showSelection(item.frame, in: window)
    }

    private func showSelection(_ frame: CGRect, in window: UIWindow) {
        guard let scene = window.windowScene else { return }
        if selectionWindow == nil || selectionWindow?.windowScene !== scene {
            let overlay = SelectionWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1000
            overlay.backgroundColor = .clear
            overlay.isAccessibilityElement = false
            overlay.accessibilityElementsHidden = true
            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            selectionLayer.borderColor = UIColor.systemBlue.cgColor
            selectionLayer.borderWidth = 3
            selectionLayer.cornerRadius = 10
            selectionLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
            controller.view.layer.addSublayer(selectionLayer)
            overlay.rootViewController = controller
            overlay.isHidden = false
            selectionWindow = overlay
        }
        let local = selectionWindow?.convert(frame, from: window.screen.coordinateSpace) ?? frame
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        selectionLayer.frame = local.insetBy(dx: -4, dy: -3)
        CATransaction.commit()
        selectionWindow?.isHidden = false
    }

    private func hideSelection() {
        stopRepeat()
        selectionWindow?.isHidden = true
        currentFrame = nil
        currentLabel = nil
    }
}
