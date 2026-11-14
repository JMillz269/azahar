// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

/// One entry of the in-game control center.
struct HUDAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isOn = false
    var isDestructive = false
    let action: () -> Void
}

/// The in-game menu: a small glass button that opens into a control center and closes back into
/// the button. The button and the panel are one glass view whose frame and corners animate between
/// the two (a material before iOS 26).
struct GameHUD: View {
    @Binding var isOpen: Bool
    let title: String
    let actions: [HUDAction]
    /// Where the menu button sits and how big it is (it is placed with the controller layout).
    let menuFrame: CGRect
    let menuScale: CGFloat
    /// The swap screens button, nil when it is turned off.
    let swapFrame: CGRect?
    let swapScale: CGFloat
    /// How the menu and swap buttons look while closed: the glass setting of the controller.
    var glass = ControlGlassStyle()
    /// Faded out (the buttons only, an open panel stays): a controller is in use.
    var concealed = false
    let onSwap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = panelSize(in: geometry.size)
            let panelFrame = CGRect(x: (geometry.size.width - size.width) / 2,
                                    y: panelCenterY(in: geometry.size) - size.height / 2,
                                    width: size.width, height: size.height)
            // The button and the panel are ONE glass view whose frame and corners animate
            // between the button and the panel. That gives the morph without a
            // GlassEffectContainer: a container the size of the screen made the system capture
            // the whole game picture behind it, which flashed over the game.
            let frame = isOpen ? panelFrame : menuFrame

            ZStack {
                if isOpen {
                    // A tap beside the panel closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        // Hidden from accessibility (and so from the controller navigation):
                        // as a full-screen "button" it showed up as a selectable game screen.
                        // The close button of the panel does the same for those.
                        .accessibilityHidden(true)
                }

                ZStack {
                    MenuButtonIcon(scale: menuScale, onGlass: true)
                        .frame(width: menuFrame.width, height: menuFrame.height)
                        .opacity(isOpen ? 0 : 1)
                        .accessibilityHidden(isOpen)

                    // The panel keeps its full size and is scaled down into the button, so its
                    // layout does not reflow while the glass grows.
                    panel(size: size)
                        .scaleEffect(isOpen ? 1 : min(menuFrame.width / size.width,
                                                       menuFrame.height / size.height))
                        .opacity(isOpen ? 1 : 0)
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(LGPanelShape())
                .lgGlass(in: LGPanelShape(), tint: isOpen ? .regular : buttonTint)
                .overlay {
                    if !isOpen {
                        Button {
                            withAnimation(LGMotion.panel) { isOpen = true }
                        } label: {
                            Color.clear.contentShape(LGPanelShape())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Emulation menu")
                    }
                }
                .position(x: frame.midX, y: frame.midY)

                if !isOpen, let swapFrame {
                    Button(action: onSwap) {
                        SwapButtonIcon(scale: swapScale, onGlass: true)
                            .frame(width: swapFrame.width, height: swapFrame.height)
                            .lgGlass(in: Circle(), tint: buttonTint)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Swap screens")
                    .transition(.opacity)
                    .position(x: swapFrame.midX, y: swapFrame.midY)
                }
            }
            .opacity(concealed && !isOpen ? 0 : 1)
            .allowsHitTesting(!(concealed && !isOpen))
            .accessibilityHidden(concealed && !isOpen)
            .animation(.easeInOut(duration: 0.4), value: concealed)
        }
    }

    private var buttonTint: LGTint {
        glass.enabled ? .control(glass.tint) : .clear
    }

    private func close() {
        withAnimation(LGMotion.panel) { isOpen = false }
    }

    // MARK: Panel

    private func panelWidth(in size: CGSize) -> CGFloat {
        min(size.width - 24, 560)
    }

    private func panelMaxHeight(in size: CGSize) -> CGFloat {
        max(160, size.height - 32)
    }

    private func panelCenterY(in size: CGSize) -> CGFloat {
        size.height / 2
    }

    /// The panel's size: as wide as fits (at most 560 points), as tall as its tiles need,
    /// scrolling when the screen is too short.
    private func panelSize(in size: CGSize) -> CGSize {
        let width = panelWidth(in: size)
        let rows = Int((Double(actions.count) / Double(columns(for: width))).rounded(.up))
        let wanted = CGFloat(rows) * 76 + 64
        return CGSize(width: width, height: min(wanted, panelMaxHeight(in: size)))
    }

    private func columns(for width: CGFloat) -> Int {
        max(3, Int((width - 24) / 84))
    }

    private func panel(size: CGSize) -> some View {
        let columnCount = columns(for: size.width)
        return VStack(spacing: 8) {
            HStack {
                // 3DS titles often hold a line break ("The Legend of Zelda" / "Majora's Mask 3D"),
                // which with a one line limit cut the title after the first line.
                Text(title.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " "))
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
            }
            .padding(.horizontal, 6)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                         count: columnCount),
                          spacing: 4) {
                    ForEach(actions) { action in
                        Button {
                            close()
                            action.action()
                        } label: {
                            tile(action)
                        }
                        .buttonStyle(HUDTileStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .frame(width: size.width, height: size.height)
    }

    private func tile(_ action: HUDAction) -> some View {
        let color: Color = action.isDestructive ? .red : (action.isOn ? .accentColor : .primary)
        return VStack(spacing: 5) {
            Image(systemName: action.systemImage)
                .font(.system(size: 21, weight: .medium))
                .frame(height: 26)
            Text(action.title)
                .font(.system(size: 10.5, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 68)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A tile of the control center: no surface of its own (it sits on the panel's glass), it only
/// gives under the finger.
private struct HUDTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(LGMotion.press, value: configuration.isPressed)
    }
}
