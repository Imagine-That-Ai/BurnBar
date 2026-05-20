import SwiftUI
import OpenBurnBarCore

// MARK: - Storage scope visuals

/// Mobile mirror of `ProviderAccountStorage` on the Mac. Shared label / icon /
/// tint helpers so a single account reads the same way in popover, dashboard
/// and Settings on every device.
enum ProviderAccountStorageVisual {
    static func label(_ scope: ProviderAccountStorageScope) -> String {
        switch scope {
        case .cloudRefreshable, .serverPrivate:
            return "Cloud"
        case .deviceKeychain:
            return "Mac Keychain"
        case .localOnly:
            return "Local"
        }
    }

    static func iconName(_ scope: ProviderAccountStorageScope) -> String {
        switch scope {
        case .cloudRefreshable, .serverPrivate:
            return "icloud.fill"
        case .deviceKeychain:
            return "lock.shield"
        case .localOnly:
            return "internaldrive"
        }
    }

    static func tint(_ scope: ProviderAccountStorageScope) -> Color {
        switch scope {
        case .cloudRefreshable, .serverPrivate:
            return MobileTheme.whimsy
        case .deviceKeychain:
            return MobileTheme.amber
        case .localOnly:
            return MobileTheme.Colors.textMuted
        }
    }

    static func description(_ scope: ProviderAccountStorageScope) -> String {
        switch scope {
        case .cloudRefreshable:
            return "Stored in OpenBurnBar Cloud. Refreshable from any signed-in device."
        case .serverPrivate:
            return "Stored server-side. Quota is refreshed remotely; the credential is not visible here."
        case .deviceKeychain:
            return "Stored only on your Mac. Quota refreshes from there — this iPhone reads the synced result."
        case .localOnly:
            return "Tracked locally. Removing the account will not delete it from any cloud."
        }
    }

    static func canRefreshFromMobile(_ scope: ProviderAccountStorageScope) -> Bool {
        switch scope {
        case .cloudRefreshable, .serverPrivate: return true
        case .deviceKeychain, .localOnly: return false
        }
    }
}

struct ProviderAccountStorageChip: View {
    let scope: ProviderAccountStorageScope
    var compact: Bool = false

    var body: some View {
        let tint = ProviderAccountStorageVisual.tint(scope)
        return HStack(spacing: 4) {
            Image(systemName: ProviderAccountStorageVisual.iconName(scope))
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(ProviderAccountStorageVisual.label(scope))
                .font(MobileTheme.Typography.tiny)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stored in \(ProviderAccountStorageVisual.label(scope))")
        .accessibilityHint(Text(ProviderAccountStorageVisual.description(scope)))
    }
}

// MARK: - Status visuals

enum ProviderAccountStatusVisual {
    static func label(_ status: ProviderAccountStatus, isRefreshing: Bool = false) -> String {
        if isRefreshing { return "Refreshing" }
        switch status {
        case .connected: return "Connected"
        case .stale: return "Stale"
        case .error: return "Needs attention"
        case .disconnected: return "Disconnected"
        case .disabled: return "Disabled"
        case .deleted: return "Removed"
        }
    }

    static func iconName(_ status: ProviderAccountStatus, isRefreshing: Bool = false) -> String {
        if isRefreshing { return "arrow.triangle.2.circlepath" }
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle.slash"
        case .disabled: return "pause.circle"
        case .deleted: return "trash.slash"
        }
    }

    static func tint(_ status: ProviderAccountStatus, isRefreshing: Bool = false) -> Color {
        if isRefreshing { return MobileTheme.whimsy }
        switch status {
        case .connected: return MobileTheme.Colors.success
        case .stale: return MobileTheme.Colors.warning
        case .error: return MobileTheme.Colors.error
        case .disconnected, .disabled, .deleted: return MobileTheme.Colors.textMuted
        }
    }
}

struct ProviderAccountStatusChip: View {
    let status: ProviderAccountStatus
    var isRefreshing: Bool = false
    var compact: Bool = false

    var body: some View {
        let tint = ProviderAccountStatusVisual.tint(status, isRefreshing: isRefreshing)
        return HStack(spacing: 4) {
            Image(systemName: ProviderAccountStatusVisual.iconName(status, isRefreshing: isRefreshing))
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(ProviderAccountStatusVisual.label(status, isRefreshing: isRefreshing))
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProviderAccountStatusVisual.label(status, isRefreshing: isRefreshing))
    }
}

struct DefaultAccountChip: View {
    var compact: Bool = false

    var body: some View {
        Text("Default")
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.accent)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(MobileTheme.Colors.accent.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Default account")
    }
}

struct ProviderAccountStorageSummary: View {
    let accounts: [ProviderAccountDoc]

    private var counts: [(scope: ProviderAccountStorageScope, count: Int)] {
        let order: [ProviderAccountStorageScope] = [
            .cloudRefreshable,
            .serverPrivate,
            .deviceKeychain,
            .localOnly
        ]
        return order.compactMap { scope in
            let active = accounts.filter { $0.storageScope == scope && $0.status != .deleted }
            guard !active.isEmpty else { return nil }
            return (scope, active.count)
        }
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.xs) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    Image(systemName: ProviderAccountStorageVisual.iconName(entry.scope))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorageVisual.tint(entry.scope))
                    Text("\(entry.count) \(ProviderAccountStorageVisual.label(entry.scope))")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
