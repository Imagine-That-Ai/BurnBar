import SwiftUI
import OpenBurnBarCore

// MARK: - Identity Hero
//
// Profile header. Animated rotating ember halo, status pill, sync ring that
// pulses on writes, and a CTA strip for sign out.

struct IdentityHero: View {
    let displayName: String
    let email: String?
    let photoURL: URL?
    let syncHealth: CloudSyncHealth
    let connectionsCount: Int

    @State private var haloRotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner, padding: 22) {
            VStack(spacing: MobileTheme.Spacing.lg) {
                avatar
                identity
                healthLine
                syncDetail
            }
        }
        .onAppear { startHalo() }
    }

    // MARK: - Avatar

    private var avatar: some View {
        ZStack {
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            MobileTheme.ember,
                            MobileTheme.amber,
                            MobileTheme.blaze,
                            MobileTheme.ember.opacity(0.0),
                            MobileTheme.ember
                        ],
                        center: .center
                    ),
                    lineWidth: 2
                )
                .frame(width: 116, height: 116)
                .rotationEffect(.degrees(haloRotation))
                .shadow(color: MobileTheme.ember.opacity(0.55), radius: 18)

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 92, height: 92)
                .overlay(
                    Circle().stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.5)
                )

            if let photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(Circle())
            } else {
                fallbackAvatar
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
            }
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.primaryGradient)
            Text(initials)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first.map(String.init) }.joined()
        return initials.uppercased().isEmpty ? "OB" : initials.uppercased()
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 4) {
            Text(displayName)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
            if let email {
                Text(email)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            statusPill
        }
    }

    private var statusPill: some View {
        let statusText: String
        let statusColor: Color
        switch syncHealth {
        case .healthy:
            statusText = "Synced · \(connectionsCount) provider\(connectionsCount == 1 ? "" : "s")"
            statusColor = MobileTheme.success
        case .syncing:
            statusText = "Syncing…"
            statusColor = MobileTheme.amber
        case .offline:
            statusText = "Offline"
            statusColor = MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked:
            statusText = "Cloud unreachable"
            statusColor = MobileTheme.error
        case .permissionDenied:
            statusText = "Access denied"
            statusColor = MobileTheme.error
        case .degraded:
            statusText = "Degraded"
            statusColor = MobileTheme.warning
        case .unknown:
            statusText = "Checking…"
            statusColor = MobileTheme.Colors.textMuted
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(statusColor.opacity(0.16)))
        .overlay(Capsule().stroke(statusColor.opacity(0.4), lineWidth: 0.5))
    }

    private var healthLine: some View {
        EmptyView()
    }

    @ViewBuilder
    private var syncDetail: some View {
        if syncHealth.isHealthy {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
                Text("Live cloud sync · App Check active")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    // MARK: - Animation

    private func startHalo() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
            haloRotation = 360
        }
    }
}
