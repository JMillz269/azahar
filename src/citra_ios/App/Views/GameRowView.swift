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

    var body: some View {
        HStack(spacing: 16) {
            GameIconView(icon: game.icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(game.publisher.isEmpty ? game.programIDString : game.publisher)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
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
                Text(game.publisher)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemBackground)))
        .overlay(alignment: .topTrailing) {
            if game.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
