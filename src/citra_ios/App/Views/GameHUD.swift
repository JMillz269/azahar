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
/// the button. The button and the panel are one piece of glass that morphs (iOS 26); before, the
/// panel is a material card that scales in.
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
    let onSwap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isOpen {
                    // A tap beside the panel closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityLabel("Close menu")
                        .accessibilityAddTraits(.isButton)
                }

                // No GlassEffectContainer: one the size of the screen made the system capture
                // the whole game picture behind it, which flashed over the game. The button and
                // the panel each carry their own glass and materialize in and out.
                ZStack {
                    if isOpen {
                        panel(in: geometry.size)
                            .lgGlass(in: LGPanelShape())
                            .lgPanelTransition(anchor: .top)
                            .position(x: geometry.size.width / 2,
                                      y: panelCenterY(in: geometry.size))
                    } else {
                        Button {
                            withAnimation(LGMotion.panel) { isOpen = true }
                        } label: {
                            MenuButtonIcon(scale: menuScale, onGlass: true)
                                .frame(width: menuFrame.width, height: menuFrame.height)
                                .lgGlass(in: Circle(), tint: .clear)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Emulation menu")
                        .lgPanelTransition(anchor: .top)
                        .position(x: menuFrame.midX, y: menuFrame.midY)

                        if let swapFrame {
                            Button(action: onSwap) {
                                SwapButtonIcon(scale: swapScale, onGlass: true)
                                    .frame(width: swapFrame.width, height: swapFrame.height)
                                    .lgGlass(in: Circle(), tint: .clear)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Swap screens")
                            .position(x: swapFrame.midX, y: swapFrame.midY)
                        }
                    }
                }
            }
        }
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

    private func panel(in size: CGSize) -> some View {
        let width = panelWidth(in: size)
        let columns = max(3, Int((width - 24) / 84))
        let rows = Int((Double(actions.count) / Double(columns)).rounded(.up))
        // Title, the tiles and the padding around them; scrolls when the screen is too short.
        let wanted = CGFloat(rows) * 76 + 64
        return VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
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
                                         count: columns),
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
        .frame(width: width, height: min(wanted, panelMaxHeight(in: size)))
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
