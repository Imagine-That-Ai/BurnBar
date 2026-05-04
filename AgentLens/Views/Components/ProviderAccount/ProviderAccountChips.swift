import SwiftUI
import OpenBurnBarCore

// MARK: - Storage scope

/// Single source of truth for the human-readable label + system glyph that
/// describes where a `ProviderAccountDoc` keeps its credential. Used by
/// both Settings and Dashboard surfaces so the same account always reads the
/// same way regardless of where it appears.
enum ProviderAccountStorage {
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
            return DesignSystem.Colors.whimsy
        case .deviceKeychain:
            return DesignSystem.Colors.amber
        case .localOnly:
            return DesignSystem.Colors.textMuted
        }
    }

    static func description(_ scope: ProviderAccountStorageScope) -> String {
        switch scope {
        case .cloudRefreshable:
            return "Stored in OpenBurnBar Cloud. Refreshable from any signed-in device."
        case .serverPrivate:
            return "Stored server-side. Quota is refreshed remotely; the credential is not visible here."
        case .deviceKeychain:
            return "Stored only in this Mac's Keychain. Quota refreshes from this Mac."
        case .localOnly:
            return "Tracked locally on this Mac. Removing it will not delete it from any cloud."
        }
    }
}

struct ProviderAccountStorageChip: View {
    let scope: ProviderAccountStorageScope
    var compact: Bool = false

    var body: some View {
        let tint = ProviderAccountStorage.tint(scope)
        return HStack(spacing: 4) {
            Image(systemName: ProviderAccountStorage.iconName(scope))
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(ProviderAccountStorage.label(scope))
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stored in \(ProviderAccountStorage.label(scope))")
        .accessibilityHint(Text(ProviderAccountStorage.description(scope)))
    }
}

// MARK: - Status

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
        if isRefreshing { return DesignSystem.Colors.whimsy }
        switch status {
        case .connected: return DesignSystem.Colors.success
        case .stale: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .disconnected, .disabled, .deleted: return DesignSystem.Colors.textMuted
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
                .font(DesignSystem.Typography.tiny)
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

// MARK: - Provider group summary strip

/// Compact "2 Cloud · 1 Mac Keychain" strip used to give a provider-level
/// hint of where the accounts live without enumerating them. Built off the
/// same scope helpers so the chips and the strip can never disagree.
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
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    Image(systemName: ProviderAccountStorage.iconName(entry.scope))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorage.tint(entry.scope))
                    Text("\(entry.count) \(ProviderAccountStorage.label(entry.scope))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
