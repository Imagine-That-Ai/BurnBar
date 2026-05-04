import SwiftUI
import OpenBurnBarCore

/// Maximum accounts per provider during onboarding.
enum SwitcherOnboardingLimits {
    static var providerCap: Int { 3 }
}

struct SwitcherOnboardingScanAddStep: View {
    @ObservedObject var discoveryService: SwitcherDiscoveryService
    let dataStore: DataStore
    let providerOrder: [OnboardingProvider]

    @State private var isSigningInGoogle = false
    @State private var isSigningInApple = false
    @State private var connectingCLIType: SwitcherCLIProfileType?
    @State private var showAPIKeySheet = false
    @State private var selectedCLIType: SwitcherCLIProfileType = .codex
    @State private var apiKeyInput = ""
    @State private var apiKeyLabel = ""
    @State private var capMessage: String?

    private var addedIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.isAdded }
    }

    private var notInstalledIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.authState == .notInstalled }
    }

    private var alreadyAddedIdentities: [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { $0.isAlreadyAdded && !$0.isAdded }
    }

    private var addedCount: Int {
        addedIdentities.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Header
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Add Your Accounts")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Connect accounts provider-by-provider. BurnBar keeps the flow quick: launch the login, finish it, and come back to stack reserves behind your primary account.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let capMessage {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(capMessage)
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(DesignSystem.Colors.warning)
                .transition(.opacity)
            }

            // Provider-guided sections
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ForEach(providerOrder) { provider in
                        providerSection(for: provider)
                    }

                    // Not installed identities (flat, at the bottom)
                    let notInstalled = notInstalledIdentities
                    if !notInstalled.isEmpty {
                        Divider().background(DesignSystem.Colors.borderSubtle)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Not on this Mac")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)

                            ForEach(notInstalled) { identity in
                                NotInstalledCard(identity: identity)
                            }
                        }
                    }
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
        .sheet(isPresented: $showAPIKeySheet) {
            APIKeyEntrySheet(
                cliType: $selectedCLIType,
                apiKey: $apiKeyInput,
                label: $apiKeyLabel,
                onSubmit: {
                    guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let cliKind: OnboardingProvider.Kind
                    switch selectedCLIType {
                    case .codex: cliKind = .codexCLI
                    case .claude: cliKind = .claudeCLI
                    case .opencode: cliKind = .openCodeCLI
                    }
                    guard enforceCap(for: cliKind) else { return }
                    withAnimation(DesignSystem.Animation.snappy) {
                        _ = discoveryService.addCLIWithAPIKey(
                            cliType: selectedCLIType,
                            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                            label: apiKeyLabel.isEmpty ? nil : apiKeyLabel,
                            dataStore: dataStore
                        )
                    }
                    showAPIKeySheet = false
                    apiKeyInput = ""
                    apiKeyLabel = ""
                }
            )
        }
    }

    // MARK: - Provider Section

    @ViewBuilder
    private func providerSection(for provider: OnboardingProvider) -> some View {
        let identities = identitiesForProvider(provider)
        let added = addedCountForProvider(provider)
        let already = alreadyAddedCountForProvider(provider)
        let total = added + already
        let providerCap = SwitcherOnboardingLimits.providerCap
        let isAtCap = total >= providerCap

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            // Section header with count
            HStack(spacing: DesignSystem.Spacing.xs) {
                Group {
                    if provider.hasBundledLogo {
                        Image(provider.bundledLogoName!)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: provider.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(provider.color)
                    }
                }
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                Text(provider.label.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(provider.color)
                    .tracking(0.8)

                Spacer()

                Text("\(total)/\(providerCap) added")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isAtCap ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.xs)

            // Identity cards for this provider
            VStack(spacing: 2) {
                ForEach(identities) { identity in
                    IdentityCard(
                        identity: identity,
                        onAdd: { addIdentity(identity) },
                        onSignIn: { signInIdentity(identity) },
                        onDifferentAccount: { differentAccount(for: identity) }
                    )
                }
            }

            // Add-another actions for this provider
            if !isAtCap {
                providerAddActions(for: provider)
            } else if total > 0 {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Provider cap reached (\(providerCap))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func providerAddActions(for provider: OnboardingProvider) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            switch provider.kind {
            case .chrome:
                differentAccountButton(
                    title: "Add another Google account",
                    subtitle: "Sign into Chrome with a different Google account",
                    icon: "person.badge.key.fill",
                    color: DesignSystem.Colors.coral,
                    isLoading: isSigningInGoogle
                ) {
                    await signInDifferentGoogle()
                }

                webProviderButtons(provider: provider)

            case .safari:
                differentAccountButton(
                    title: "Add another Apple account",
                    subtitle: "Sign into Safari with a different Apple ID",
                    icon: "apple.logo",
                    color: DesignSystem.Colors.textSecondary,
                    isLoading: isSigningInApple
                ) {
                    await signInDifferentApple()
                }

                webProviderButtons(provider: provider)

            case .openAI:
                differentAccountButton(
                    title: "Sign in to OpenAI / Codex",
                    subtitle: "Open chatgpt.com to log in or switch account",
                    icon: "bubble.left",
                    color: Color(hex: "00A67E"),
                    isLoading: false
                ) {
                    openWebDestination(.openAI)
                }

            case .claude:
                differentAccountButton(
                    title: "Sign in to Claude",
                    subtitle: "Open claude.ai to log in or switch account",
                    icon: "bubble.right",
                    color: Color(hex: "CC785C"),
                    isLoading: false
                ) {
                    openWebDestination(.claude)
                }

            case .codexCLI:
                differentAccountButton(
                    title: "Connect another Codex account",
                    subtitle: "Launch Codex login and keep this provider ready for handoff",
                    icon: "link.badge.plus",
                    color: Color(hex: "00A67E"),
                    isLoading: connectingCLIType == .codex
                ) {
                    await connectDifferentCLI(.codex)
                }

            case .claudeCLI:
                differentAccountButton(
                    title: "Connect another Claude Code account",
                    subtitle: "Launch Claude Code login and keep another reserve on deck",
                    icon: "link.badge.plus",
                    color: Color(hex: "CC785C"),
                    isLoading: connectingCLIType == .claude
                ) {
                    await connectDifferentCLI(.claude)
                }

            case .openCodeCLI:
                differentAccountButton(
                    title: "Add OpenCode via API key",
                    subtitle: "Enter an API key for a different OpenCode account",
                    icon: "key.fill",
                    color: DesignSystem.Colors.whimsy,
                    isLoading: false
                ) {
                    selectedCLIType = .opencode
                    showAPIKeySheet = true
                }
            }
        }
    }

    @ViewBuilder
    private func webProviderButtons(provider: OnboardingProvider) -> some View {
        differentAccountButton(
            title: "Open \(provider.kind == .chrome ? "OpenAI / Codex" : "OpenAI / Codex")",
            subtitle: "Open chatgpt.com to log in or switch",
            icon: "bubble.left",
            color: Color(hex: "00A67E"),
            isLoading: false
        ) {
            openWebDestination(.openAI)
        }

        differentAccountButton(
            title: "Open Claude",
            subtitle: "Open claude.ai to log in or switch",
            icon: "bubble.right",
            color: Color(hex: "CC785C"),
            isLoading: false
        ) {
            openWebDestination(.claude)
        }
    }

    // MARK: - Provider Identity Helpers

    private func identitiesForProvider(_ provider: OnboardingProvider) -> [DiscoveredIdentity] {
        discoveryService.discoveredIdentities.filter { identity in
            guard identity.authState != .notInstalled, !identity.isAlreadyAdded else { return false }
            return identityMatchesProvider(identity, provider)
        }
    }

    private func addedCountForProvider(_ provider: OnboardingProvider) -> Int {
        addedIdentities.filter { identityMatchesProvider($0, provider) }.count
    }

    private func alreadyAddedCountForProvider(_ provider: OnboardingProvider) -> Int {
        alreadyAddedIdentities.filter { identityMatchesProvider($0, provider) }.count
    }

    private func identityMatchesProvider(_ identity: DiscoveredIdentity, _ provider: OnboardingProvider) -> Bool {
        switch (identity.source, provider.kind) {
        case (.chromeProfile, .chrome): return true
        case (.safari, .safari): return true
        case (.codex, .codexCLI): return true
        case (.codex, .openAI): return true
        case (.claudeCode, .claudeCLI): return true
        case (.claudeCode, .claude): return true
        case (.opencode, .openCodeCLI): return true
        default: return false
        }
    }

    // MARK: - Cap Enforcement

    private func enforceCap(for kind: OnboardingProvider.Kind) -> Bool {
        let provider = OnboardingProvider.defaultOrder.first { $0.kind == kind } ?? OnboardingProvider.defaultOrder[0]
        let total = addedCountForProvider(provider) + alreadyAddedCountForProvider(provider)
        let providerCap = SwitcherOnboardingLimits.providerCap
        if total >= providerCap {
            withAnimation(DesignSystem.Animation.snappy) {
                capMessage = "\(provider.label) cap reached (\(providerCap)). Remove one first or continue."
            }
            return false
        }
        capMessage = nil
        return true
    }

    // MARK: - Web Destination

    private func openWebDestination(_ destination: AccountChangeDestination) {
        guard let url = URL(string: destination == .openAI ? "https://chatgpt.com/" : "https://claude.ai/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func differentAccountButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        isLoading: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // MARK: - Actions

    private func addIdentity(_ identity: DiscoveredIdentity) {
        let kind = onboardingKind(for: identity)
        guard enforceCap(for: kind) else { return }

        withAnimation(DesignSystem.Animation.snappy) {
            _ = discoveryService.addIdentity(identity, dataStore: dataStore)
        }

        Task {
            _ = await discoveryService.verifyIdentity(identity)
        }
    }

    private func signInIdentity(_ identity: DiscoveredIdentity) {
        switch identity.source {
        case .codex, .claudeCode:
            if let cliType = identity.source.cliType {
                Task { await connectDifferentCLI(cliType) }
            }
        case .chromeProfile:
            Task { await signInDifferentGoogle() }
        case .safari:
            Task { await signInDifferentApple() }
        case .opencode:
            addIdentity(identity)
        }
    }

    private func differentAccount(for identity: DiscoveredIdentity) {
        switch identity.source {
        case .chromeProfile:
            Task { await signInDifferentGoogle() }
        case .safari:
            Task { await signInDifferentApple() }
        case .codex, .claudeCode:
            if let cliType = identity.source.cliType {
                Task { await connectDifferentCLI(cliType) }
            }
        case .opencode:
            if let cliType = identity.source.cliType {
                selectedCLIType = cliType
            }
            showAPIKeySheet = true
        }
    }

    private func onboardingKind(for identity: DiscoveredIdentity) -> OnboardingProvider.Kind {
        switch identity.source {
        case .chromeProfile: return .chrome
        case .safari: return .safari
        case .codex: return .codexCLI
        case .claudeCode: return .claudeCLI
        case .opencode: return .openCodeCLI
        }
    }

    private func signInDifferentGoogle() async {
        guard enforceCap(for: .chrome) else { return }
        isSigningInGoogle = true
        defer { isSigningInGoogle = false }
        _ = await discoveryService.addDifferentGoogleAccount(dataStore: dataStore)
    }

    private func signInDifferentApple() async {
        guard enforceCap(for: .safari) else { return }
        isSigningInApple = true
        defer { isSigningInApple = false }
        _ = await discoveryService.addDifferentAppleAccount(dataStore: dataStore)
    }

    private func connectDifferentCLI(_ cliType: SwitcherCLIProfileType) async {
        let kind: OnboardingProvider.Kind
        switch cliType {
        case .codex:
            kind = .codexCLI
        case .claude:
            kind = .claudeCLI
        case .opencode:
            kind = .openCodeCLI
        }

        guard enforceCap(for: kind) else { return }
        connectingCLIType = cliType
        defer { connectingCLIType = nil }

        if let profile = await discoveryService.addDifferentCLIAccount(cliType: cliType, dataStore: dataStore) {
            withAnimation(DesignSystem.Animation.snappy) {
                capMessage = "Connected \(profile.displayName). Add another if you want a deeper reserve."
            }
        }
    }
}

// MARK: - API Key Entry Sheet

private struct APIKeyEntrySheet: View {
    @Binding var cliType: SwitcherCLIProfileType
    let apiKey: Binding<String>
    let label: Binding<String>
    let onSubmit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Header
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Add API Key")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Enter an API key for a different account. The key is stored securely in your Keychain.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // CLI type picker
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Tool")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Picker("Tool", selection: $cliType) {
                    ForEach(cliTypes, id: \.rawValue) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            // API key field
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("API Key")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                SecureField("sk-...", text: apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.mono)
            }

            // Label field
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Label (optional)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                TextField("Work, Personal, etc.", text: label)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.caption)
            }

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                Button("Add Key") {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.amber)
                .font(DesignSystem.Typography.caption)
                .disabled(apiKey.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(width: 360, height: 300)
        .background(DesignSystem.Colors.background)
    }
}

private extension APIKeyEntrySheet {
    var cliTypes: [SwitcherCLIProfileType] {
        var types: [SwitcherCLIProfileType] = []
        types.reserveCapacity(3)
        types.append(.codex)
        types.append(.claude)
        types.append(.opencode)
        return types
    }
}

// MARK: - Identity Card

private struct IdentityCard: View {
    let identity: DiscoveredIdentity
    let onAdd: () -> Void
    let onSignIn: () -> Void
    let onDifferentAccount: () -> Void

    @State private var isHovered = false
    @State private var showDifferentOption = false

    var body: some View {
        GlassCard(interactive: true) {
            VStack(spacing: 0) {
                // Main row
                HStack(spacing: DesignSystem.Spacing.md) {
                    identityIcon
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text(identity.displayTitle)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)

                            authStateBadge
                        }

                        Text(identity.accountAssociationText)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let detail = identity.identityDetailText {
                            Text(detail)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let quotaSummary = identity.quotaSummary {
                            quotaSummaryView(quotaSummary)
                        }
                    }

                    Spacer()

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

                // "Different account" row — shown on hover/tap for browser/CLI identities
                if showDifferentOption && !identity.isAdded && identity.authState != .notInstalled {
                    Divider()
                        .background(DesignSystem.Colors.borderSubtle)
                        .padding(.horizontal, DesignSystem.Spacing.md)

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Text(differentAccountLabel)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        Button("Add different") {
                            onDifferentAccount()
                        }
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.amber)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.surface.opacity(0.5))
                }
            }
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                isHovered = hovering
                showDifferentOption = hovering
            }
        }
        .onTapGesture {
            withAnimation(DesignSystem.Animation.snappy) {
                showDifferentOption.toggle()
            }
        }
    }

    private var differentAccountLabel: String {
        switch identity.source {
        case .chromeProfile:
            return "Signed in with a different Google account?"
        case .safari:
            return "Use a different Apple ID?"
        case .codex, .claudeCode, .opencode:
            return "Connect another account for this provider?"
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

    // MARK: - Quota

    private func quotaSummaryView(_ summary: IdentityQuotaSummary) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            quotaPill(label: "5h", value: summary.fiveHourRemaining ?? "--")
            quotaPill(label: "Weekly", value: summary.weeklyRemaining ?? "--")
        }
        .padding(.top, DesignSystem.Spacing.xxs)
    }

    private func quotaPill(label: String, value: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Text(label)
                .font(DesignSystem.Typography.monoTiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(value)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.success)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.78))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        if identity.authState == .notAuthenticated && identity.source.cliType != nil {
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

// MARK: - Added Card (recently added via different-account flow)

private struct AddedCard: View {
    let identity: DiscoveredIdentity

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.success)

            VStack(alignment: .leading, spacing: 1) {
                Text(identity.displayTitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(identity.accountAssociationText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)

                if let detail = identity.identityDetailText {
                    Text(detail)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if identity.isVerified {
                Text("Verified")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .padding(.horizontal, DesignSystem.Spacing.sm)
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

            VStack(alignment: .leading, spacing: 1) {
                Text(identity.displayTitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(identity.accountAssociationText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

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

private extension DiscoveredIdentity {
    var accountAssociationText: String {
        switch source {
        case .chromeProfile(_, let email, let gaiaName, let serviceIdentities):
            var segments: [String] = []

            if let email = normalized(email) {
                segments.append("Google: \(email)")
            } else if let gaiaName = normalized(gaiaName) {
                segments.append("Google: \(gaiaName)")
            }

            segments.append(contentsOf: serviceIdentities.map(\.displaySummary))

            if !segments.isEmpty {
                return segments.joined(separator: " · ")
            }
            return "Not logged in"

        case .safari:
            if let email = extractedEmail(from: subtitle) {
                return "Logged in as \(email)"
            }
            if authState == .authenticated {
                return "Signed in (Apple ID email unavailable)"
            }
            return "Not logged in"

        case .codex(_, _, _, let accountDescription, _), .claudeCode(_, _, let accountDescription, _):
            if let accountDescription = normalized(accountDescription) {
                switch authState {
                case .authenticated:
                    return "Logged in as \(accountDescription)"
                case .apiKeyPresent:
                    return "API key for \(accountDescription)"
                case .notAuthenticated:
                    return "Not logged in"
                case .notInstalled:
                    return "Not installed"
                }
            }

            switch authState {
            case .authenticated:
                return "Logged in (account email unavailable)"
            case .apiKeyPresent:
                return "API key detected (account email unavailable)"
            case .notAuthenticated:
                return "Not logged in"
            case .notInstalled:
                return "Not installed"
            }

        case .opencode:
            switch authState {
            case .authenticated:
                return "Logged in"
            case .apiKeyPresent:
                return "API key detected"
            case .notAuthenticated:
                return "Not logged in"
            case .notInstalled:
                return "Not installed"
            }
        }
    }

    var identityDetailText: String? {
        switch source {
        case .chromeProfile(let folderKey, _, _, _):
            return "Chrome profile: \(folderKey)"
        case .safari:
            return subtitle
        case .codex(let executablePath, _, _, _, _):
            return normalized(executablePath) ?? subtitle
        case .claudeCode(let executablePath, _, _, _):
            return normalized(executablePath) ?? subtitle
        case .opencode(let executablePath):
            return normalized(executablePath) ?? subtitle
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractedEmail(from value: String?) -> String? {
        guard let value = normalized(value), value.contains("@") else { return nil }
        let components = value.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        if let email = components.first(where: { $0.contains("@") }) {
            return String(email)
        }
        return nil
    }
}
