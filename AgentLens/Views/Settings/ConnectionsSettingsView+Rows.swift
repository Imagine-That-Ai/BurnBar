import AppKit
import OpenBurnBarCore
import SwiftUI

// Connection route-readiness, provider/account rows, OAuth rows, quota pills, migration/app-connect cards, sheets, and wizard target.
// Extracted from ConnectionsSettingsView.swift (god-file decomposition) — same module, verbatim.

enum ConnectionsRouteReadiness {
    static func hasAnyRouteReadyProvider(
        configurations: [OpenBurnBarDaemonProviderConfiguration]
    ) -> Bool {
        configurations.contains { configuration in
            isRouteReady(configuration)
        }
    }

    static func hasRouteReadyProvider(
        for target: RoutingClientWiringTarget,
        configurations: [OpenBurnBarDaemonProviderConfiguration]
    ) -> Bool {
        let supportedFormats = gatewayFormatFamiliesServing(target)
        guard !supportedFormats.isEmpty else { return false }

        return configurations.contains { configuration in
            guard isRouteReady(configuration),
                  supportedFormats.contains(formatFamily(forProviderID: configuration.providerID)) else {
                return false
            }
            return true
        }
    }

    private static func isRouteReady(
        _ configuration: OpenBurnBarDaemonProviderConfiguration
    ) -> Bool {
        configuration.isEnabled
            && configuration.hasRoutingCapability
            && configuration.credentialSlots.contains { slot in
                slot.canAttemptRoute()
        }
    }

    /// The local gateway owns the endpoint bridge. A route-ready Anthropic
    /// provider can serve OpenAI-shaped clients, and a route-ready
    /// OpenAI-compatible provider can serve Claude Code's `/v1/messages` through
    /// the Messages bridge. This predicate is intentionally about endpoint
    /// reachability, not native upstream protocol family.
    private static func gatewayFormatFamiliesServing(
        _ target: RoutingClientWiringTarget
    ) -> Set<BurnBarProviderFormatFamily> {
        switch target {
        case .claudeCode, .codex, .opencode, .forge, .droid, .grok:
            return [.anthropic, .openaiCompat]
        case .antigravity, .cursorAgent:
            return []
        }
    }

    private static func formatFamily(forProviderID providerID: String) -> BurnBarProviderFormatFamily {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID) {
            return catalogProvider.formatFamily
        }
        if let agentProvider = AgentProvider.fromProviderID(ProviderID(rawValue: providerID))
            ?? AgentProvider.fromCatalogProviderID(providerID),
           agentProvider == .claudeCode {
            return .anthropic
        }
        return .openaiCompat
    }
}

/// One provider's slice of the Accounts list. Shows the failover chain
/// (Active now / Next fallback chips), each account with a single status
/// line, and a "+ Add another <Provider> account" button that anchors the
/// multi-account-per-provider premise.
struct ProviderAccountGroup: View {
    let providerID: ProviderID
    let accounts: [ProviderAccountDoc]
    var externalAccounts: [ConnectionsSettingsView.ExternalOAuthAccount] = []
    let routingState: ProviderRoutingStateSnapshot?
    var quotaWindowsForAccount: (ProviderAccountDoc) -> [SwitcherQuotaWindowDisplay] = { _ in [] }
    var quotaWindowsForExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> [SwitcherQuotaWindowDisplay] = { _ in [] }
    var credentialNoticeForExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> ConnectionsSettingsView.ExternalOAuthCredentialNotice? = { _ in nil }
    var credentialMessageForExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> String? = { _ in nil }
    var isRefreshingExternalCredential: (ConnectionsSettingsView.ExternalOAuthAccount) -> Bool = { _ in false }
    let onTapAccount: (ProviderAccountDoc) -> Void
    var onTapExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> Void = { _ in }
    var onRefreshExternalCredential: (ConnectionsSettingsView.ExternalOAuthAccount) -> Void = { _ in }
    let onAddAnother: () -> Void

    private var provider: AgentProvider? {
        AgentProvider.fromProviderID(providerID) ?? AgentProvider.fromCatalogProviderID(providerID.rawValue)
    }

    private var providerDisplayName: String {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            return catalogProvider.displayName
        }
        return provider?.displayName ?? providerID.rawValue
    }

    private var providerBrand: ProviderBrand {
        ProviderBrand(providerID: providerID.rawValue)
    }

    private var activeAccountID: String? { routingState?.activeAccount?.accountID }
    private var nextFallbackAccountID: String? { routingState?.nextFallback?.accountID }
    private var totalAccountCount: Int { accounts.count + externalAccounts.count }

    /// One-line rotation summary derived from the accounts themselves. The
    /// user never sees the internal `ProviderRouterMode` distinction — they
    /// just see "auto-rotate" / "<account> first" so they know what to expect.
    private var rotationSummary: String {
        if totalAccountCount == 1 { return "single account" }
        if let preferred = accounts.first(where: { $0.isDefault }) {
            return "tries \(preferred.label) first"
        }
        return "auto-rotate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            if let provider, SettingsManager.shared.visualCaptureSourceToggleEnabled {
                VisualCaptureToggle(provider: provider, settingsManager: SettingsManager.shared)
                    .settingsAnchor("agents.visualSurface.\(provider.persistedToken)")
            }
            ForEach(accounts) { account in
                AccountRowView(
                    account: account,
                    isActive: account.id == activeAccountID,
                    isNextFallback: account.id == nextFallbackAccountID,
                    cooldownUntil: cooldownUntil(for: account.id),
                    quotaWindows: quotaWindowsForAccount(account),
                    onTap: { onTapAccount(account) }
                )
            }
            ForEach(externalAccounts) { account in
                ExternalOAuthAccountRowView(
                    account: account,
                    quotaWindows: quotaWindowsForExternalAccount(account),
                    credentialNotice: credentialNoticeForExternalAccount(account),
                    actionMessage: credentialMessageForExternalAccount(account),
                    isRefreshingCredential: isRefreshingExternalCredential(account),
                    onTap: { onTapExternalAccount(account) },
                    onRefreshCredential: { onRefreshExternalCredential(account) }
                )
            }
            if totalAccountCount == 1 {
                singleAccountHint
            }
            Button(action: onAddAnother) {
                Label("Add another \(providerDisplayName) account", systemImage: "plus")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Add another \(providerDisplayName) account")
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(providerBrand.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                CatalogProviderLogoView(brand: providerBrand, size: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(providerDisplayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(totalAccountCount) account\(totalAccountCount == 1 ? "" : "s") · \(rotationSummary)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private var singleAccountHint: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text("Add another account to enable automatic failover when this one runs out.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
    }

    private func cooldownUntil(for accountID: String) -> Date? {
        if accountID == activeAccountID { return routingState?.activeAccount?.cooldownUntil }
        if accountID == nextFallbackAccountID { return routingState?.nextFallback?.cooldownUntil }
        return routingState?.exhaustedOrCoolingDownAccounts.first { $0.accountID == accountID }?.cooldownUntil
    }
}

/// One account inside a provider group. Single status, single routing chip
/// (Active now / Next fallback / cooldown), tappable to edit. No chip stack.
struct AccountRowView: View {
    let account: ProviderAccountDoc
    let isActive: Bool
    let isNextFallback: Bool
    let cooldownUntil: Date?
    let quotaWindows: [SwitcherQuotaWindowDisplay]
    let onTap: () -> Void

    private var statusTint: Color {
        ProviderAccountStatusVisual.tint(account.status)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        routingChip
                    }
                    if let detail = detailLine {
                        Text(detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !quotaWindows.isEmpty {
                        ConnectionQuotaWindowPills(windows: quotaWindows)
                    }
                }
                Spacer()
                Image(systemName: ProviderAccountStorage.iconName(account.storageScope))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProviderAccountStorage.tint(account.storageScope))
                    .help(ProviderAccountStorage.description(account.storageScope))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(isActive
                        ? DesignSystem.Colors.success.opacity(0.06)
                        : DesignSystem.Colors.background.opacity(0.45)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(isActive
                        ? DesignSystem.Colors.success.opacity(0.4)
                        : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var routingChip: some View {
        if isActive {
            chip(label: "Active now", systemImage: "checkmark.circle.fill", tint: DesignSystem.Colors.success)
        } else if isNextFallback {
            chip(label: "Next fallback", systemImage: "arrow.triangle.branch", tint: DesignSystem.Colors.amber)
        } else if let cooldown = cooldownUntil, cooldown > Date() {
            chip(label: "Cooling down", systemImage: "clock.fill", tint: DesignSystem.Colors.warning)
        } else if account.status == .error {
            chip(label: "Sign-in needed", systemImage: "exclamationmark.triangle.fill", tint: DesignSystem.Colors.error)
        } else if account.status == .stale {
            chip(label: "Stale", systemImage: "clock.badge.exclamationmark", tint: DesignSystem.Colors.warning)
        }
    }

    private func chip(label: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var detailLine: String? {
        if account.status == .deleted {
            return "Removed from this Mac"
        }
        if let cooldown = cooldownUntil, cooldown > Date() {
            return "Resumes \(cooldown.formatted(.relative(presentation: .named)))"
        }
        if account.status == .error, let code = account.lastErrorCode {
            return "Last error: \(code)"
        }
        if let identity = account.identityHint, !identity.isEmpty, identity != account.label {
            return identity
        }
        if let last = account.lastRefreshAt {
            return "Refreshed \(last.formatted(.relative(presentation: .named)))"
        }
        return nil
    }

    private var accessibilityLabel: String {
        var parts: [String] = [account.label]
        if isActive { parts.append("active now") } else if isNextFallback { parts.append("next fallback") }
        parts.append(ProviderAccountStatusVisual.label(account.status))
        parts.append("stored in \(ProviderAccountStorage.label(account.storageScope))")
        return parts.joined(separator: ", ")
    }
}

struct ExternalOAuthAccountRowView: View {
    let account: ConnectionsSettingsView.ExternalOAuthAccount
    let quotaWindows: [SwitcherQuotaWindowDisplay]
    let credentialNotice: ConnectionsSettingsView.ExternalOAuthCredentialNotice?
    let actionMessage: String?
    let isRefreshingCredential: Bool
    let onTap: () -> Void
    let onRefreshCredential: () -> Void

    private var tint: Color {
        if account.isDisabled { return DesignSystem.Colors.textMuted }
        return credentialNotice?.tint ?? DesignSystem.Colors.success
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button(action: onTap) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                    rowText
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailingControls
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.background.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(tint.opacity(account.isDisabled ? 0.18 : 0.36), lineWidth: 0.5)
        )
        .opacity(account.isDisabled ? 0.66 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowText: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.label)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                HFlowLayout(horizontalSpacing: 6, verticalSpacing: DesignSystem.Spacing.xxs) {
                    chip(
                        label: account.isCurrentLogin ? "Current login" : "OAuth profile",
                        systemImage: account.isCurrentLogin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark",
                        tint: account.isDisabled ? DesignSystem.Colors.textMuted : DesignSystem.Colors.success
                    )
                    if let credentialNotice {
                        chip(
                            label: credentialNotice.title,
                            systemImage: credentialNotice.systemImage,
                            tint: credentialNotice.tint
                        )
                    }
                    if account.isDisabled {
                        chip(label: "Disabled", systemImage: "pause.circle.fill", tint: DesignSystem.Colors.textMuted)
                    }
                }
            }
            Text(account.statusText)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let credentialNotice {
                Text(credentialNotice.message)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.medium)
                    .foregroundStyle(credentialNotice.tint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionMessage {
                Text(actionMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = account.detail {
                Text(detail)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !quotaWindows.isEmpty {
                ConnectionQuotaWindowPills(windows: quotaWindows)
            }
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 6) {
            if shouldShowRefreshCredential {
                Button(action: onRefreshCredential) {
                    if isRefreshingCredential {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Label("Refresh credential", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(credentialNotice?.tint ?? DesignSystem.Colors.ember)
                .disabled(account.isDisabled || isRefreshingCredential)
                .help("Refresh this \(account.cliType.displayName) OAuth credential")
            }

            Image(systemName: account.isCurrentLogin ? "terminal.fill" : "person.crop.circle.badge.checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .help(account.isCurrentLogin ? "Default local CLI login" : "Isolated OAuth profile")
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var shouldShowRefreshCredential: Bool {
        credentialNotice != nil || account.isCurrentLogin
    }

    private func chip(label: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var accessibilityLabel: String {
        var parts = [account.label, account.isCurrentLogin ? "current login" : "OAuth profile"]
        if account.isDisabled { parts.append("disabled") }
        if let credentialNotice {
            parts.append(credentialNotice.title)
        }
        if !quotaWindows.isEmpty {
            parts.append("quota \(quotaWindows.map(\.inlineText).joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}

struct ConnectionQuotaWindowPills: View {
    let windows: [SwitcherQuotaWindowDisplay]

    var body: some View {
        HFlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xxs) {
            ForEach(windows) { window in
                HStack(spacing: 4) {
                    Text(window.label)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(window.remaining)
                        .font(DesignSystem.Typography.monoTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text(window.resetText)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(DesignSystem.Colors.surfaceElevated.opacity(0.72))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
            }
        }
    }
}

struct VibeProxyMigrationCard: View {
    let snapshot: VibeProxyMigrationSnapshot?
    let state: VibeProxyMigrationState
    let onScan: () -> Void
    let onMigrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                    headerIdentity
                    Spacer()
                    actionButtons
                }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                        headerIdentity
                        Spacer(minLength: 0)
                    }
                    actionButtons
                }
            }

            if let snapshot, snapshot.foundAnything {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    metricChip(
                        "\(snapshot.importableRecords.count)",
                        label: "secrets"
                    )
                    metricChip(
                        "\(snapshot.detectedTargets.count)",
                        label: "apps"
                    )
                    if !snapshot.reconnectRecords.isEmpty {
                        metricChip(
                            "\(snapshot.reconnectRecords.count)",
                            label: "reconnect"
                        )
                    }
                    if !snapshot.disabledRecords.isEmpty {
                        metricChip(
                            "\(snapshot.disabledRecords.count)",
                            label: "disabled"
                        )
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var summaryText: String {
        switch state {
        case .idle:
            return "Import VibeProxy keys and switch detected CLI configs to OpenBurnBar's local gateway."
        case .scanning:
            return "Scanning ~/.cli-proxy-api and CLI config files."
        case .ready:
            guard let snapshot else { return "Scan complete." }
            if !snapshot.foundAnything {
                return "No VibeProxy credentials or app configs were found."
            }
            if !snapshot.importableRecords.isEmpty && !snapshot.detectedTargets.isEmpty {
                return "Ready to import supported secrets and switch detected apps."
            }
            if !snapshot.importableRecords.isEmpty {
                return "Ready to import supported API keys. No VibeProxy app configs need rewriting."
            }
            if !snapshot.detectedTargets.isEmpty {
                return "Detected app configs can be switched. Subscription logins still need OpenBurnBar reconnect."
            }
            return "Only local subscription logins were found. Reconnect them in OpenBurnBar."
        case .importing:
            return "Importing credentials and rewriting detected app configs."
        case .completed(let message):
            return message
        case .error(let message):
            return message
        }
    }

    private var headerIdentity: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.blaze)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move from VibeProxy")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(summaryText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button(action: onScan) {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(state.isBusy)

            Button(action: onMigrate) {
                if state.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Moving...")
                    }
                } else {
                    Label("Import & Switch", systemImage: "arrow.right.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(state.isBusy || snapshot?.foundAnything == false)
        }
    }

    private func metricChip(_ value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
            Text(label)
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.68))
        )
        .overlay(
            Capsule()
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }
}

//
// `ProxyModelCatalogPanel`, `ProxyModelProviderGroup`, `ProxyModelProviderSection`,
// and `ProxyModelCatalogRow` live in their own file so both the embedded catalog
// here and the dedicated Settings → Agents → Models page can share them.
// See `ProxyModelCatalogPanel.swift`.

/// One row per CLI in the Apps section, designed as a "routing cockpit
/// instrument" with three visual zones.
///
/// **Zone 1 (left) - Identity:** A pulsing status dot colored by lifecycle
/// state, the provider logo, client name, and an endpoint-shape badge
/// (Responses, Messages, Chat Completions).
///
/// **Zone 2 (center) - Status cluster:** Badges for connection state, freshness,
/// and source identity. A monospace metadata strip surfaces model counts and
/// probe endpoint as instrument readouts.
///
/// **Zone 3 (right) - Action:** The next obvious primary action (Connect + Sync,
/// Sync models, Retry probe, Disconnect) with a more-options menu.
///
/// The smart button auto-enables the gateway and runs wire + probe in one
/// click. Busy states animate the status indicator. Stale-to-current and
/// degraded-to-healthy transitions use a gentle spring.
struct AppConnectRow: View {
    let target: RoutingClientWiringTarget
    let state: AppConnectState
    let isDisabled: Bool
    let modelSummary: RoutedClientModelSummary?
    let onConnect: () -> Void
    let onTest: () -> Void
    let onSyncModels: () -> Void
    let onRepair: () -> Void
    let onDisconnect: () -> Void
    let onShowSnippet: () -> Void
    let onRevealFile: () -> Void
    let configPath: String

    private var provider: AgentProvider? {
        switch target {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .opencode: return .openCode
        case .forge: return .forgeDev
        case .droid: return .factory
        case .grok: return .xAI
        case .cursorAgent: return .cursorAgent
        case .antigravity: return .antigravity
        }
    }

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — a 3pt vertical strip that tints with the
            // connection state so the row reads at a glance even in
            // peripheral vision. Invisible when disconnected so the row
            // stays calm and inviting.
            leftAccentBar
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                statusIndicator
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    identityRow
                    badgeRow
                    metadataStrip
                    if let detail = detailLine {
                        Text(detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(isDegraded ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                trailingColumn
            }
            .padding(DesignSystem.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(rowBorder)
        .opacity(isDisabled ? 0.62 : 1)
        .animation(DesignSystem.Animation.gentle, value: state)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Left accent bar

    /// A subtle 3pt vertical accent strip on the left edge of the row. It
    /// glows with the connection state color so the row's health is readable
    /// in peripheral vision. Fades to transparent when disconnected so the
    /// row stays calm and inviting rather than alarming.
    private var leftAccentBar: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        accentBarColor.opacity(accentBarOpacity),
                        accentBarColor.opacity(accentBarOpacity * 0.4)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .padding(.leading, DesignSystem.Spacing.xs)
            .animation(DesignSystem.Animation.gentle, value: state)
    }

    private var accentBarColor: Color {
        switch state {
        case .connected: return DesignSystem.Colors.success
        case .degraded: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .connecting, .syncingModels, .probing: return DesignSystem.Colors.amber
        case .notConnected, .unknown: return DesignSystem.Colors.textMuted
        }
    }

    private var accentBarOpacity: Double {
        switch state {
        case .connected: return 0.7
        case .degraded, .error: return 0.6
        case .connecting, .syncingModels, .probing: return 0.5
        case .notConnected, .unknown: return 0.0
        }
    }

    // MARK: - Zone 1: Identity

    /// Pulsing status indicator with a subtle outer glow ring that animates
    /// during busy and connected states so the row feels alive. Connected
    /// rows get a gentle breathing ring; busy rows get a faster pulse;
    /// disconnected rows are a calm flat dot.
    private var statusIndicator: some View {
        ZStack {
            // Outer glow ring — visible when connected or busy
            if isConnected || isBusy {
                Circle()
                    .fill(statusTint.opacity(isBusy ? 0.25 : 0.15))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isBusy ? 1.0 : 0.85)
                    .opacity(isBusy ? 0.8 : 0.5)
                    .animation(
                        isBusy
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isBusy ? isBusy : isConnected
                    )
            }
            // Inner dot
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .strokeBorder(statusTint.opacity(0.3), lineWidth: 1)
                        .frame(width: 11, height: 11)
                        .opacity(isConnected ? 0.6 : 0)
                )
        }
        .frame(width: 16, height: 16)
    }

    private var identityRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let provider {
                ProviderLogoView(provider: provider, size: 18, useFallbackColor: true)
            }
            Text(target.displayName)
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
            endpointBadge
        }
    }

    /// Compact endpoint-shape badge communicating the wire format and trust
    /// path (Responses, Messages, Chat Completions). Reads as an instrument
    /// label, not decorative chrome.
    private var endpointBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: endpointIcon)
                .font(.system(size: 8, weight: .semibold))
            Text(target.endpointBadgeLabel)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.4))
    }

    private var endpointIcon: String {
        switch target {
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .codex: return "bolt.horizontal.fill"
        case .opencode, .forge, .droid, .grok: return "terminal.fill"
        case .antigravity, .cursorAgent: return "person.crop.circle.badge.questionmark"
        }
    }

    // MARK: - Zone 2: Status cluster

    @ViewBuilder
    private var badgeRow: some View {
        if badges.isEmpty {
            EmptyView()
        } else {
            HFlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xs) {
                ForEach(badges, id: \.id) { badge in
                    RoutedClientStateBadge(
                        badge: badge,
                        isPrimary: badge.id != "native" && badge.id != "probe-endpoint"
                    )
                }
            }
        }
    }

    /// Monospace metadata strip with model counts and probe endpoint rendered
    /// as quiet instrument readouts beneath the badges. Items are separated by
    /// subtle dot dividers so they read as distinct instruments, not a blur.
    @ViewBuilder
    private var metadataStrip: some View {
        let items = metadataItems
        if !items.isEmpty {
            HFlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xxs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Text("\u{00B7}")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: 8, weight: .semibold))
                        }
                        Text(item.text)
                            .font(DesignSystem.Typography.monoTiny)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(item.tint)
                }
            }
            .padding(.top, 1)
        }
    }

    private struct MetadataItem {
        let text: String
        let icon: String?
        let tint: Color
    }

    private var metadataItems: [MetadataItem] {
        var items: [MetadataItem] = []
        if let count = modelSummary?.openburnbarCountLabel {
            items.append(MetadataItem(
                text: count,
                icon: "cylinder.split.1x2.fill",
                tint: DesignSystem.Colors.textSecondary
            ))
        }
        if let native = modelSummary?.nativeCountLabel {
            items.append(MetadataItem(
                text: native,
                icon: "shippingbox.fill",
                tint: DesignSystem.Colors.textSecondary
            ))
        }
        if let endpoint = target.probeEndpointLabel {
            items.append(MetadataItem(
                text: endpoint,
                icon: "network",
                tint: DesignSystem.Colors.textMuted
            ))
        }
        return items
    }

    private var badges: [RoutedClientBadge] {
        var result: [RoutedClientBadge] = []
        if isDisabled {
            result.append(.init(
                id: "no-route",
                label: "No route-ready account",
                systemImage: "exclamationmark.triangle.fill",
                tint: DesignSystem.Colors.warning
            ))
            return result
        }
        if let native = modelSummary?.nativeBadgeText {
            result.append(.init(
                id: "native",
                label: native,
                systemImage: "square.stack.3d.up.fill",
                tint: DesignSystem.Colors.whimsy
            ))
        }
        switch state {
        case .connected:
            if let summary = modelSummary, summary.openburnbarModelCount > 0 {
                result.append(.init(
                    id: "current",
                    label: "Current",
                    systemImage: "checkmark.seal.fill",
                    tint: DesignSystem.Colors.success
                ))
            } else if target.supportsModelSync {
                result.append(.init(
                    id: "sync-available",
                    label: "Sync available",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: DesignSystem.Colors.amber
                ))
            } else {
                result.append(.init(
                    id: "connected",
                    label: "Connected",
                    systemImage: "checkmark.circle.fill",
                    tint: DesignSystem.Colors.success
                ))
            }
        case .notConnected, .unknown:
            result.append(.init(
                id: "disconnected",
                label: "Disconnected",
                systemImage: "circle.slash",
                tint: DesignSystem.Colors.textMuted
            ))
        case .connecting, .probing, .syncingModels:
            // Busy states show a pulsing indicator in Zone 1, not a badge.
            break
        case .degraded(let message):
            if Self.isCatalogStaleMessage(message) {
                result.append(.init(
                    id: "stale",
                    label: "Stale catalog",
                    systemImage: "clock.badge.exclamationmark",
                    tint: DesignSystem.Colors.warning
                ))
            } else {
                result.append(.init(
                    id: "probe-failed",
                    label: "Probe failed",
                    systemImage: "xmark.octagon.fill",
                    tint: DesignSystem.Colors.error
                ))
            }
        case .error:
            result.append(.init(
                id: "error",
                label: "Error",
                systemImage: "xmark.octagon.fill",
                tint: DesignSystem.Colors.error
            ))
        }
        return result
    }

    // MARK: - Zone 3: Trailing column

    @ViewBuilder
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
            if let provider {
                ProviderQuotaChip(provider: provider)
            }
            primaryAction
            if isConnected {
                Menu {
                    Button("Test connection", action: onTest)
                    Button("Show shell snippet", action: onShowSnippet)
                    Button("Reveal config file", action: onRevealFile)
                        .help(configPath)
                    Divider()
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isHovering ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                        .animation(DesignSystem.Animation.hover, value: isHovering)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("More options for \(target.displayName)")
            }
        }
    }

    // MARK: - State machine surface

    private var isConnected: Bool {
        if case .connected = state { return true }
        if case .degraded = state { return true }
        return false
    }

    private var isBusy: Bool {
        state.isBusy
    }

    private var statusTint: Color {
        if isDisabled {
            return DesignSystem.Colors.warning
        }
        switch state {
        case .connected: return DesignSystem.Colors.success
        case .connecting, .syncingModels, .probing: return DesignSystem.Colors.textSecondary
        case .degraded: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .notConnected, .unknown: return DesignSystem.Colors.textMuted
        }
    }

    private var detailLine: String? {
        if isDisabled {
            return missingRouteText
        }
        switch state {
        case .connected:
            if modelSummary?.openburnbarModelCount == nil, !target.supportsModelSync {
                return "Connected via local gateway"
            }
            return nil
        case .syncingModels: return "Syncing models from BurnBar's live catalog…"
        case .connecting: return "Connecting to local gateway…"
        case .probing: return "Testing gateway endpoint…"
        case .degraded(let message):
            return message
        case .error(let message): return message
        case .notConnected:
            return target.endpointDescription
        case .unknown:
            return target.endpointDescription
        }
    }

    private var missingRouteText: String {
        switch target {
        case .claudeCode:
            return "No route-ready OpenBurnBar model is enabled for /v1/messages. Add or enable a provider account first."
        case .codex, .opencode, .forge, .droid, .cursorAgent:
            return "No route-ready OpenBurnBar account is enabled for this gateway endpoint. Add or enable a provider account first."
        case .antigravity:
            return "No route-ready Antigravity profile is enabled. Add or enable an Antigravity account first."
        case .grok:
            return "No route-ready xAI account is enabled. Add or enable an xAI API key first."
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .notConnected, .unknown:
            Button(action: onConnect) {
                Label(target.supportsModelSync ? "Connect + Sync" : "Connect",
                      systemImage: target.supportsModelSync ? "bolt.horizontal.circle.fill" : "powerplug.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDisabled)
        case .connecting, .syncingModels:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state == .syncingModels ? "Syncing…" : "Connecting…")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        case .connected:
            if target.supportsModelSync {
                Button(action: onSyncModels) {
                    Label("Sync models", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
            } else {
                Button(action: onTest) {
                    Label("Test", systemImage: "stethoscope")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
            }
        case .degraded(let message):
            if Self.isCatalogStaleMessage(message), target.supportsModelSync {
                Button(action: onSyncModels) {
                    Label("Sync models", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.warning)
                .controlSize(.small)
            } else {
                Button(action: onRepair) {
                    Label("Retry probe", systemImage: "arrow.clockwise.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.warning)
                .controlSize(.small)
            }
        case .error:
            Button(action: onConnect) {
                Label("Retry", systemImage: "arrow.clockwise.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.error)
            .controlSize(.small)
        }
    }

    // MARK: - Visuals

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .fill(
                isDegraded
                    ? AnyShapeStyle(DesignSystem.Colors.warning.opacity(0.06))
                    : isError
                        ? AnyShapeStyle(DesignSystem.Colors.error.opacity(0.04))
                        : isHovering && !isDisabled
                            ? AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.5))
                            : AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.3))
            )
            .animation(DesignSystem.Animation.hover, value: isHovering)
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .stroke(
                isDegraded
                    ? DesignSystem.Colors.warning.opacity(0.38)
                    : isError
                        ? DesignSystem.Colors.error.opacity(0.3)
                        : DesignSystem.Colors.border.opacity(0.4),
                lineWidth: 0.5
            )
    }

    private var isDegraded: Bool {
        if case .degraded = state { return true }
        return false
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = [target.displayName]
        if let provider {
            parts.append("provider \(provider.displayName)")
        }
        parts.append(target.endpointBadgeLabel)
        switch state {
        case .connected: parts.append("connected")
        case .connecting: parts.append("connecting")
        case .syncingModels: parts.append("syncing models")
        case .probing: parts.append("testing")
        case .degraded(let message):
            parts.append(Self.isCatalogStaleMessage(message) ? "stale catalog, needs sync" : "probe failed, needs retry")
        case .error(let message): parts.append("error: \(message)")
        case .notConnected: parts.append("disconnected")
        case .unknown: parts.append("unknown state")
        }
        if isDisabled { parts.append("no route-ready account") }
        if let count = modelSummary?.countLabel { parts.append(count) }
        return parts.joined(separator: ", ")
    }

    private static func isCatalogStaleMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("model list is stale")
            || normalized.contains("model catalog is stale")
            || normalized.contains("discovery catalog is stale")
    }
}

// MARK: - Routed Client Badge

struct RoutedClientBadge: Identifiable, Hashable {
    let id: String
    let label: String
    let systemImage: String
    let tint: Color
}

/// Reusable capsule badge for routed-client state and freshness signals.
/// Shared across Droid, Codex, and Claude Code rows so the three clients
/// read as one coherent system with equal visual weight.
///
/// Badges use a two-tier visual hierarchy:
///   - **Primary** (state badges): stronger tint background, full-opacity text
///   - **Secondary** (info badges): lighter background, slightly muted text
struct RoutedClientStateBadge: View {
    let badge: RoutedClientBadge
    var isPrimary: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(badge.label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(isPrimary ? badge.tint : badge.tint.opacity(0.75))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            badge.tint.opacity(isPrimary ? 0.12 : 0.08)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(badge.tint.opacity(isPrimary ? 0.15 : 0.08), lineWidth: 0.4)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.label)
    }
}

struct ConnectionsAddAccountButtonStyle: ButtonStyle {
    enum Size {
        case compact
        case regular

        var height: CGFloat {
            switch self {
            case .compact: return 30
            case .regular: return 36
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: return 12
            case .regular: return 14
            }
        }

        var font: Font {
            switch self {
            case .compact: return DesignSystem.Typography.caption
            case .regular: return DesignSystem.Typography.body
            }
        }
    }

    let size: Size

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.blaze,
                        DesignSystem.Colors.amber
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.16 : 0.28), lineWidth: 0.6)
            )
            .shadow(
                color: DesignSystem.Colors.blaze.opacity(configuration.isPressed ? 0.12 : 0.22),
                radius: configuration.isPressed ? 3 : 7,
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule(style: .continuous))
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct SnippetSheet: View {
    let target: RoutingClientWiringTarget
    let snippet: String
    let isCopied: Bool
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("\(target.displayName) — shell snippet")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text("Paste these into `~/.zshrc`, `~/.bashrc`, or your shell of choice. Restart \(target.displayName) so it picks up the env vars.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ScrollView {
                Text(snippet)
                    .font(DesignSystem.Typography.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
            HStack {
                Button(action: onCopy) {
                    if isCopied {
                        Label("Copied!", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Copy to clipboard", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 540, minHeight: 380)
    }
}

/// Identifiable wrapper so the wizard sheet can present-by-item without
/// dropping the provider ID across navigation churn.
struct ProviderWizardTarget: Equatable, Identifiable {
    let providerID: String?
    let startsAtProviderSelection: Bool

    var id: String {
        startsAtProviderSelection ? "add-account" : providerID ?? "provider-dashboard"
    }

    static let addAccount = ProviderWizardTarget(
        providerID: nil,
        startsAtProviderSelection: true
    )

    init(providerID: String) {
        self.providerID = providerID
        self.startsAtProviderSelection = false
    }

    private init(providerID: String?, startsAtProviderSelection: Bool) {
        self.providerID = providerID
        self.startsAtProviderSelection = startsAtProviderSelection
    }
}
