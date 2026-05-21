import SwiftUI
import OpenBurnBarMedia

/// Header card for `MercuryLiveSheet`. Renders the avatar, the
/// (potentially nicknamed) device name, and a caller-supplied
/// `statusStrip` slot — the parent passes in `MercuryLiveStatusStrip`
/// (interactive live chips) so this view stays focused on identity
/// chrome and the strip stays focused on live data.
struct MercuryHeaderCard<Status: View>: View {
    let peer: MercuryPeer
    let nickname: String
    let badges: [MercuryBadgeKind]
    let accent: Color
    let pulse: Bool
    let avatarStyle: MercuryAvatarStyle
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

                statusStrip()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
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
        )
        .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 10)
    }

    @ViewBuilder
    private func badgePill(for badge: MercuryBadgeKind) -> some View {
        let text = badgeText(for: badge)
        let silverGradient = LinearGradient(
            colors: [
                Color(red: 0.78, green: 0.75, blue: 0.71), // hermesMercury
                Color(red: 0.64, green: 0.67, blue: 0.73).opacity(0.5) // hermesAureate
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        HStack(spacing: 6) {
            Image(systemName: badge.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(silverGradient)
            
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay(
                Capsule()
                    .stroke(silverGradient, lineWidth: 1.0)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1.5)
        )
    }

    private func badgeText(for badge: MercuryBadgeKind) -> String {
        switch badge {
        case .architecture: return "Apple Silicon"
        case .os:           return "macOS Sequoia"
        case .lastSeen:     return relativeLastSeen(peer.lastSeenAt)
        case .battery, .hostname, .ip, .app:
            return "—"
        }
    }

    private func relativeLastSeen(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
