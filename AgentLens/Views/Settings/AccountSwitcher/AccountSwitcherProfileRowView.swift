import SwiftUI
import OpenBurnBarCore

// MARK: - Profile Row View

/// Individual profile row with active indicator, account identity, and actions.
struct ProfileRowView: View {
    let profile: SwitcherProfileRecord
    let priorityIndex: Int
    let fallbackIndex: Int?          // position within its provider pool (1-based), nil if solo
    let providerColor: Color
    let quotaLookup: (AgentProvider) -> ProviderQuotaSnapshot?
    let isActive: Bool
    let isChangingAccount: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canSwap: Bool
    let canSetPrimary: Bool
    let canToggleDisabled: Bool
    let onSetActive: () -> Void
    let onSwap: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleDisabled: () -> Void
    let onChangeAccount: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    // Legacy convenience init (for any call site that omits the new params)
    init(
        profile: SwitcherProfileRecord,
        priorityIndex: Int,
        fallbackIndex: Int? = nil,
        providerColor: Color = DesignSystem.Colors.textMuted,
        quotaLookup: @escaping (AgentProvider) -> ProviderQuotaSnapshot? = { _ in nil },
        isActive: Bool,
        isChangingAccount: Bool = false,
        canMoveUp: Bool,
        canMoveDown: Bool,
        canSwap: Bool = false,
        canSetPrimary: Bool = false,
        canToggleDisabled: Bool = false,
        onSetActive: @escaping () -> Void,
        onSwap: @escaping () -> Void = {},
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onToggleDisabled: @escaping () -> Void = {},
        onChangeAccount: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.profile = profile
        self.priorityIndex = priorityIndex
        self.fallbackIndex = fallbackIndex
        self.providerColor = providerColor
        self.quotaLookup = quotaLookup
        self.isActive = isActive
        self.isChangingAccount = isChangingAccount
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.canSwap = canSwap
        self.canSetPrimary = canSetPrimary
        self.canToggleDisabled = canToggleDisabled
        self.onSetActive = onSetActive
        self.onSwap = onSwap
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onToggleDisabled = onToggleDisabled
        self.onChangeAccount = onChangeAccount
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Provider color accent bar + active dot
                ZStack(alignment: .center) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(providerColor.opacity(isActive ? 1.0 : 0.25))
                        .frame(width: 3, height: 36)

                    if isActive {
                        Circle()
                            .fill(DesignSystem.Colors.success)
                            .frame(width: 7, height: 7)
                            .offset(y: 22)
                    }
                }
                .frame(width: 8)

                // Profile identity
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(profile.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if profile.isDisabled {
                            Text("Paused")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        if isConnected {
                            Text("Logged in")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.success)
                                .clipShape(Capsule())
                        }

                        if let idx = fallbackIndex {
                            Text(idx == 1 ? "primary" : "reserve \(idx - 1)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(providerColor.opacity(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(providerColor.opacity(0.10))
                                .clipShape(Capsule())
                        }
                    }

                    // Account identity line — the most important info
                    Text(accountIdentityText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(accountIdentityColor)

                    if !cliQuotaWindows.isEmpty {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            ForEach(cliQuotaWindows) { window in
                                quotaWindowPill(window)
                            }
                        }
                    }

                    if !browserServiceStatusLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(browserServiceStatusLines, id: \.id) { status in
                                Text(status.displayText)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                Spacer()

                // Actions (visible on hover or always for active)
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if canMoveUp {
                        Button { onMoveUp() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(profile.displayName) up in priority")
                    }

                    if canMoveDown {
                        Button { onMoveDown() } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(profile.displayName) down in priority")
                    }

                    if canSetPrimary {
                        Button("Make Primary") { onSetActive() }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(providerColor)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Make \(profile.displayName) the primary account for this provider")
                    }

                    if canSwap {
                        Button("Swap") { onSwap() }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Swap \(profile.displayName) with another account from this provider")
                    }

                    Button(profile.isDisabled ? "Enable" : "Pause") { onToggleDisabled() }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(profile.isDisabled ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                        .buttonStyle(.plain)
                        .disabled(!canToggleDisabled)
                        .accessibilityLabel("\(profile.isDisabled ? "Enable" : "Pause") \(profile.displayName)")

                    Button { onChangeAccount() } label: {
                        if isChangingAccount {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChangingAccount)
                    .accessibilityLabel("\(isConnected ? "Reconnect" : "Connect") account for \(profile.displayName)")

                    if profile.targetKind == .cli {
                        Button { onEdit() } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(profile.displayName)")
                    }

                    Button { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(profile.displayName)")
                }
                .opacity(isHovered || isConnected || profile.isDisabled ? 1 : 0.55)
            }
            .padding(.vertical, DesignSystem.Spacing.sm)
            .padding(.horizontal, DesignSystem.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.snappy) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName), \(accountIdentityText), \(isConnected ? "logged in" : "not logged in")")
        .accessibilityHint(fallbackIndex == 1 ? "Primary account for this provider" : (canSetPrimary ? "Use Make Primary to switch this provider to this account" : "Profile available for this provider"))
    }

    // MARK: - Account identity

    private var accountIdentityText: String {
        // CLI: show accountDescription from metadata if present
        if profile.targetKind == .cli {
            if profile.isDisabled {
                return "Paused — excluded from switching until re-enabled"
            }
            if let accountDescription = profile.cliMetadata?.accountDescription,
               !accountDescription.isEmpty {
                return "Connected: \(accountDescription)"
            }
            if let exhaustedUntil = profile.cliMetadata?.exhaustedUntil,
               exhaustedUntil > Date() {
                return "Held in reserve until quota resets"
            }
            if let label = profile.cliMetadata?.displayLabel, !label.isEmpty {
                return "Not connected · \(label)"
            }
            return "Not connected"
        }

        // Browser: show display label (usually email) or generic text
        if let meta = profile.browserMetadata {
            if profile.isDisabled {
                return "Paused — excluded from browser switching until re-enabled"
            }
            var segments: [String] = []

            if let email = meta.accountEmail, !email.isEmpty {
                segments.append("\(browserIdentityLabel): \(email)")
            } else if let label = meta.displayLabel, !label.isEmpty {
                segments.append("\(browserIdentityLabel): \(label)")
            }

            if !segments.isEmpty {
                return segments.joined(separator: " · ")
            }
            if !meta.serviceIdentities.isEmpty {
                return "Web sessions detected"
            }
            return "Not signed in"
        }

        return profile.browserType?.displayName ?? "Browser"
    }

    private var isConnected: Bool {
        switch profile.targetKind {
        case .cli:
            return !profile.isDisabled && !(profile.cliMetadata?.accountDescription?.isEmpty ?? true)
        case .browser:
            guard !profile.isDisabled else { return false }
            if let email = profile.browserMetadata?.accountEmail, !email.isEmpty {
                return true
            }
            return !(profile.browserMetadata?.serviceIdentities.isEmpty ?? true)
        }
    }

    private var accountIdentityColor: Color {
        if profile.isDisabled {
            return DesignSystem.Colors.textMuted
        }
        if profile.targetKind == .cli,
           profile.cliMetadata?.accountDescription?.isEmpty == false {
            return DesignSystem.Colors.success
        }
        if profile.targetKind == .cli,
           let exhaustedUntil = profile.cliMetadata?.exhaustedUntil,
           exhaustedUntil > Date() {
            return DesignSystem.Colors.warning
        }
        if accountIdentityText != "Not signed in" {
            return DesignSystem.Colors.success
        }
        return DesignSystem.Colors.textMuted
    }

    private var browserIdentityLabel: String {
        switch profile.browserType {
        case .safari:
            return "Apple ID"
        case .chrome, .none:
            return "Google"
        }
    }

    private var browserServiceStatusLines: [BrowserServiceStatusDisplay] {
        guard let serviceIdentities = profile.browserMetadata?.serviceIdentities,
              !serviceIdentities.isEmpty else {
            return []
        }

        return browserServiceStatusDisplays(
            for: serviceIdentities,
            quotaLookup: { provider in
                guard let agentProvider = provider.agentProvider else { return nil }
                return quotaLookup(agentProvider)
            }
        )
    }

    private var cliQuotaSummaryText: String? {
        cliQuotaStatusText(for: profile, quotaLookup: quotaLookup)
    }

    private var cliQuotaWindows: [SwitcherQuotaWindowDisplay] {
        cliQuotaWindowDisplays(for: profile, quotaLookup: quotaLookup) ?? []
    }

    private func quotaWindowPill(_ window: SwitcherQuotaWindowDisplay) -> some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Text("\(window.label) left")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(window.remaining)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.success)
            Text("· \(window.resetText)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.66))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
    }
}
