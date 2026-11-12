// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import SwiftUI

struct GameIconView: View {
    let icon: UIImage?
    var size: CGFloat = 55

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.18)
                        .fill(Color.gray.opacity(0.2))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.gray)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }
}

/// A row of the game list.
struct GameRowView: View {
    let game: Game
    @ObservedObject private var stats = GameStatsStore.shared

    var body: some View {
        HStack(spacing: 16) {
            GameIconView(icon: game.icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    CompatibilityBadge(game: game)
                    Text(game.publisher.isEmpty ? game.programIDString : game.publisher)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if stats.isFavorite(game) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if game.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Encrypted")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A card of the game grid.
struct GameCardView: View {
    let game: Game
    @ObservedObject private var stats = GameStatsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameIconView(icon: game.icon, size: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    CompatibilityBadge(game: game)
                    Text(game.publisher)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
        .background { ambientBackground }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { LGSpecularBorder(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
        .overlay(alignment: .topTrailing) {
            if game.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .overlay(alignment: .topLeading) {
            if stats.isFavorite(game) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The colors of the game's icon, spread out behind the card like light through frosted
    /// glass. A card is content, so it is not Liquid Glass itself; the blur is of a small still
    /// picture, which costs nothing while the library is not moving.
    @ViewBuilder private var ambientBackground: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let icon = game.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 28)
                    .saturation(1.4)
                    .opacity(0.5)
            }
        }
    }
}
