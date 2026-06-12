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
}
