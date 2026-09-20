import SwiftUI
import OpenBurnBarCore

// MARK: - Identity Hero
//
// Settings-style profile row: avatar, name, email, sync status. No halo,
// no glass card — the You list supplies the grouped background.

struct IdentityHero: View {
    let displayName: String
    let email: String?
    let photoURL: URL?
    let syncHealth: CloudSyncHealth
    let syncStatusLabel: String
    let connectionsCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                identity
                syncDetail
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Avatar

    private var avatar: some View {
        Group {
            if let photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.Colors.surfaceElevated)
            Text(initials)
                .font(.title3.weight(.semibold))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first.map(String.init) }.joined()
        return initials.uppercased().isEmpty ? "OB" : initials.uppercased()
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        case .macNotSyncing:
            statusText = syncStatusLabel
            statusColor = MobileTheme.warning
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
        case .networkDisabledOnThisDevice:
            statusText = "Cloud sync off"
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
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(statusColor)
    }

    @ViewBuilder
    private var syncDetail: some View {
        if syncHealth.isHealthy {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
                Text("Cloud sync is live")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}
