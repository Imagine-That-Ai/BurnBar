import SwiftUI
import OpenBurnBarCore

struct SwitcherOnboardingScanAddStep: View {
    @ObservedObject var discoveryService: SwitcherDiscoveryService
    let dataStore: DataStore

    private var addableIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.authState != .notInstalled && !$0.isAlreadyAdded }
    }

    private var notInstalledIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.authState == .notInstalled }
    }

    private var alreadyAddedIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.isAlreadyAdded }
    }

    private var addedCount: Int {
        discoveryService.discoveredIdentities.filter { $0.isAdded }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Header
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Add Your Identities")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Click Add for each account you want to switch between. Everything is configured automatically.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Identity cards
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    // Addable identities
                    ForEach(addableIdentities) { identity in
                        IdentityCard(
                            identity: identity,
                            onAdd: { addIdentity(identity) },
                            onSignIn: { signInIdentity(identity) }
                        )
                    }

                    // Already added
                    if !alreadyAddedIdentities.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            ForEach(alreadyAddedIdentities) { identity in
                                AlreadyAddedCard(identity: identity)
                            }
                        }
                    }

                    // Not installed
                    if !notInstalledIdentities.isEmpty {
                        Divider().background(DesignSystem.Colors.borderSubtle)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Not on this Mac")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)

                            ForEach(notInstalledIdentities) { identity in
                                NotInstalledCard(identity: identity)
                            }
                        }
                    }

                    // Manual add options
                    Divider().background(DesignSystem.Colors.borderSubtle)

                    manualAddSection
                }
            }

            // Added count
            if addedCount > 0 {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("\(addedCount) profile\(addedCount == 1 ? "" : "s") added")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Manual Add Section

    private var manualAddSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Or add manually")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    // Google Sign-In flow
                    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                    Task {
                        try? await AccountManager.shared.signInWithGoogle(presentingWindow: window)
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 10))
                        Text("Sign in with Google")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(DesignSystem.Colors.amber, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    // API key entry — reuse the existing profile form
                    Text("API key entry coming soon")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 10))
                        Text("Enter API Key")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func addIdentity(_ identity: DiscoveredIdentity) {
        withAnimation(DesignSystem.Animation.snappy) {
            _ = discoveryService.addIdentity(identity, dataStore: dataStore)
        }

        // Background verification
        Task {
            _ = await discoveryService.verifyIdentity(identity)
        }
    }

    private func signInIdentity(_ identity: DiscoveredIdentity) {
        // For unauthenticated CLIs, this would launch the auth flow
        // Currently we just add them — auth can be completed later
        addIdentity(identity)
    }
}

// MARK: - Identity Card

private struct IdentityCard: View {
    let identity: DiscoveredIdentity
    let onAdd: () -> Void
    let onSignIn: () -> Void

    @State private var isHovered = false

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Icon
                identityIcon
                    .frame(width: 28, height: 28)

                // Info
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(identity.displayTitle)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)

                        authStateBadge
                    }

                    Text(identity.subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Action button
                if identity.isAdded {
                    addedIndicator
                } else if identity.isVerifying {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    actionButton
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var identityIcon: some View {
        switch identity.source {
        case .chromeProfile:
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.coral)
        case .safari:
            Image(systemName: "safari")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.teal)
        case .codex:
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.success)
        case .claudeCode:
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.coral)
        case .opencode:
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.purple)
        }
    }

    // MARK: - Auth Badge

    @ViewBuilder
    private var authStateBadge: some View {
        switch identity.authState {
        case .authenticated:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                Text("Authenticated")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.success)

        case .apiKeyPresent:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9))
                Text("API key")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.amber)

        case .notAuthenticated:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                Text("Not signed in")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.warning)

        case .notInstalled:
            EmptyView()
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        if identity.authState == .notAuthenticated && identity.source.cliType != nil {
            // Needs auth — show Sign In
            Button("Sign In") {
                onSignIn()
            }
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.amber)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.amber, lineWidth: 1)
            )
            .buttonStyle(.plain)
        } else {
            // Ready to add
            Button("Add") {
                onAdd()
            }
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(DesignSystem.Colors.amber)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .buttonStyle(.plain)
        }
    }

    // MARK: - Added Indicator

    private var addedIndicator: some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            if identity.isVerified {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.success)
            } else if identity.verificationFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.warning)
            }

            Text(identity.isVerified ? "Verified" : (identity.verificationFailed ? "Added" : "Added"))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(identity.isVerified ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
        }
    }
}

// MARK: - Already Added Card

private struct AlreadyAddedCard: View {
    let identity: DiscoveredIdentity

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.success)

            Text(identity.displayTitle)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Spacer()

            Text("Already added")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .opacity(0.6)
    }
}

// MARK: - Not Installed Card

private struct NotInstalledCard: View {
    let identity: DiscoveredIdentity

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(identity.displayTitle)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Spacer()

            Text("Not installed")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.xxs)
    }
}
