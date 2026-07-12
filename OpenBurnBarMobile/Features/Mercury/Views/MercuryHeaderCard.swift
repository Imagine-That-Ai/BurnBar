import SwiftUI
import OpenBurnBarMedia

/// Header card for `MercuryLiveSheet`. Renders the avatar, the
/// (potentially nicknamed) device name, the user's chosen badge chips
/// (see `MercuryBadgePicker`), and a caller-supplied `statusStrip` slot —
/// the parent passes in `MercuryLiveStatusStrip` (interactive live chips)
/// so this view stays focused on identity chrome and the strip stays
/// focused on live data.
struct MercuryHeaderCard<Status: View>: View {
    let peer: MercuryPeer
    let nickname: String
    let accent: Color
    let pulse: Bool
    let avatarStyle: MercuryAvatarStyle
    /// Badge kinds picked in `MercuryCustomizeSheet` (already normalized
    /// via `MercuryDevicePersonalization.normalizedBadges()`).
    let badges: [MercuryBadgeKind]
    let reduceMotion: Bool
    @ViewBuilder let statusStrip: () -> Status

    var body: some View {
        VStack(spacing: 14) {
            MercuryAvatarView(
                style: avatarStyle,
                isOnline: peer.isOnline,
                accent: accent,
                pulse: pulse,
                reduceMotion: reduceMotion
            )

            VStack(spacing: 8) {
                Text(nickname)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(badges) { kind in
                            badgeChip(for: kind)
                        }
                    }
                }

                statusStrip()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        // Exactly one Liquid Glass layer in this cluster: the CARD plate.
        // The `statusStrip` slot hosts MercuryLiveStatusStrip, whose chips
        // stay on material/tint capsules (glass cannot sample other glass —
        // see Theme/LiquidGlass.swift), riding on this glass surface.
        .liquidGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            accent.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 10)
    }

    // MARK: - Badges

    /// One quiet capsule per picked badge kind — the same icon/label
    /// vocabulary as `MercuryBadgePicker`'s chips, on a material tint
    /// (never nested glass) so the card plate stays the only glass layer.
    private func badgeChip(for kind: MercuryBadgeKind) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(badgeText(for: kind))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(accent.opacity(0.25), lineWidth: 1)
                )
        )
        .accessibilityLabel("\(kind.displayName): \(badgeText(for: kind))")
    }

    /// Live value where `MercuryPeer` can supply one; the kind's label
    /// otherwise (kinds the Mac doesn't advertise yet — see
    /// `MercuryBadgeKind.isCurrentlyResolvable`).
    private func badgeText(for kind: MercuryBadgeKind) -> String {
        switch kind {
        case .os:
            // Mercury v1 pairs exactly one Mac per iOS device (see
            // `MercuryPeer`), so the peer's OS is known by construction.
            return "macOS"
        case .lastSeen:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: peer.lastSeenAt, relativeTo: Date())
        case .architecture, .battery, .hostname, .ip, .app:
            return kind.displayName
        }
    }
}
