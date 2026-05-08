import SwiftUI
import OpenBurnBarCore

// MARK: - Public Entry

/// Beautiful card-based provider connect wizard for iOS.
///
/// Visual + structural parity with the macOS `ProviderPlanWizardView`:
/// searchable provider grid, card-based credential method picker (no
/// `Picker(.menu)`), card-based sync-mode picker (no `Picker(.segmented)`),
/// gradient-stroked confirm hero, and animated validation chip backed by
/// `BurnBarProviderAuthRegistry.validate(_:)`.
///
/// Backend-wise this is a thin shell over `ProviderConnectionStore` /
/// `HostedQuotaSubscriptionStore` / `SelfHostedQuotaRunnerStore` — the
/// existing Functions-based connect path is preserved verbatim. iOS lacks
/// a local daemon, so the registry's "Routes on Mac" capability is shown
/// in chips for context but no proxy is built on this device.
struct MobileProviderWizardView: View {

    // MARK: - Inputs

    /// When non-nil the wizard skips the picker step and opens directly at
    /// the next step that requires user input. When nil the wizard opens at
    /// the searchable provider grid.
    let preselectedProvider: AgentProvider?
    /// Whether a hosted-quota subscription gate should be enforced when the
    /// user picks `.hosted` sync mode. Mirrors the existing onboarding step.
    let onConnected: (ProviderAccountDoc) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var step: WizardStep
    @State private var selectedProvider: AgentProvider?
    @State private var searchText: String = ""
    @State private var selectedAuthMethodID: String?
    @State private var syncMode: QuotaConnectionMode = .cloud
    @State private var credential: String = ""
    @State private var accountLabel: String = ""
    @State private var revealCredential = false
    @State private var runnerURL: String = ""
    @State private var runnerSecret: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var connectedAccount: ProviderAccountDoc?
    /// Direction of last step transition; drives the asymmetric slide animation.
    @State private var stepDirection: StepDirection = .forward
    /// Handle on the in-flight connect call so the Cancel button on `.connecting`
    /// can actually halt the network round-trip instead of leaving a phantom
    /// request that could persist a credential server-side.
    @State private var connectTask: Task<Void, Never>?

    @FocusState private var labelFocused: Bool
    @FocusState private var credentialFocused: Bool

    @State private var connectionStore = ProviderConnectionStore()
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()
    @Environment(\.dismiss) private var dismiss

    enum WizardStep: Hashable {
        case pickProvider
        case authMethod
        case syncMode
        case credential
        case connecting
        case connected
        case failed

        /// Linear ordering of steps. Used to compute slide direction so the
        /// transition feels physical: forward steps slide in from trailing,
        /// back steps slide in from leading.
        var orderIndex: Int {
            switch self {
            case .pickProvider: return 0
            case .authMethod:   return 1
            case .syncMode:     return 2
            case .credential:   return 3
            case .connecting:   return 4
            case .connected:    return 5
            case .failed:       return 4
            }
        }
    }

    enum StepDirection { case forward, backward }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader

            ScrollView {
                Group {
                    switch step {
                    case .pickProvider: pickProviderStep
                    case .authMethod:   authMethodStep
                    case .syncMode:     syncModeStep
                    case .credential:   credentialStep
                    case .connecting:   connectingStep
                    case .connected:    connectedStep
                    case .failed:       failedStep
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: stepDirection == .forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: stepDirection == .forward ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .scrollDismissesKeyboard(.interactively)

            primaryActionBar
        }
        .animation(MobileTheme.Animation.gentle, value: step)
        .task {
            await connectionStore.load()
            await subscriptionStore.load()
        }
    }

    // MARK: - Init

    init(
        preselectedProvider: AgentProvider?,
        onConnected: @escaping (ProviderAccountDoc) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preselectedProvider = preselectedProvider
        self.onConnected = onConnected
        self.onCancel = onCancel
        if let preselected = preselectedProvider {
            _step = State(initialValue: Self.firstInteractiveStep(for: preselected))
            _selectedProvider = State(initialValue: preselected)
            _selectedAuthMethodID = State(initialValue: ProviderSetupGuide.registryDescriptor(for: preselected)?.primaryMethod.id)
            let guide = ProviderSetupGuide.registryEnrichedGuide(for: preselected)
            _syncMode = State(initialValue: Self.defaultSyncMode(for: guide))
            _accountLabel = State(initialValue: guide.labelSuggestion)
        } else {
            _step = State(initialValue: .pickProvider)
            _selectedProvider = State(initialValue: nil)
        }
    }

    /// Static mirror of `nextStepAfterPicker(for:)` used at init time before
    /// `self` exists. The two implementations are intentionally identical so
    /// the wizard can never enter at a different step than back/forward
    /// navigation would land on.
    private static func firstInteractiveStep(for provider: AgentProvider) -> WizardStep {
        let descriptor = ProviderSetupGuide.registryDescriptor(for: provider)
        if (descriptor?.methods.count ?? 0) > 1 { return .authMethod }
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        if guide.supportsRemoteRunner { return .syncMode }
        return .credential
    }

    private static func defaultSyncMode(for guide: ProviderSetupGuide) -> QuotaConnectionMode {
        if guide.supportsHosted { return .hosted }
        if guide.supportsSelfHosted { return .selfHosted }
        return .cloud
    }

    // MARK: - Header

    private var wizardHeader: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                if let selectedProvider {
                    ProviderAvatar(provider: selectedProvider, mode: .aurora, size: 36)
                } else {
                    Image(systemName: "rectangle.stack.fill.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(MobileTheme.Colors.surface)
                        )
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(stepTitle)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    if let stepCaption {
                        Text(stepCaption)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                Spacer()
                MobileWizardProgressDots(
                    total: totalDots,
                    active: activeDot,
                    tint: tintColor
                )
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .background(MobileTheme.Colors.surface.opacity(0.6))
    }

    private var totalDots: Int {
        var total = 1 // pick
        let descriptor = selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }
        if (descriptor?.methods.count ?? 0) > 1 { total += 1 }
        if let provider = selectedProvider,
           ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            total += 1
        }
        total += 1 // credential
        total += 1 // result
        return total
    }

    private var activeDot: Int {
        switch step {
        case .pickProvider: return 0
        case .authMethod:   return 1
        case .syncMode:
            return (selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }?.methods.count ?? 0) > 1 ? 2 : 1
        case .credential:
            return totalDots - 2
        case .connecting, .connected, .failed:
            return totalDots - 1
        }
    }

    private var tintColor: Color {
        guard let selectedProvider else { return MobileTheme.Colors.accent }
        return MobileTheme.Colors.primary(for: selectedProvider)
    }

    private var stepTitle: String {
        switch step {
        case .pickProvider: return "Pick a provider"
        case .authMethod:   return "Pick a credential method"
        case .syncMode:     return "Pick a sync mode"
        case .credential:
            if let selectedProvider {
                if alreadyHasAccountForSelectedProvider {
                    return "Add another \(selectedProvider.displayName) account"
                }
                return "Connect \(selectedProvider.displayName)"
            }
            return "Paste your credential"
        case .connecting:   return "Connecting…"
        case .connected:    return "You're connected"
        case .failed:       return "Couldn't connect"
        }
    }

    private var alreadyHasAccountForSelectedProvider: Bool {
        guard let provider = selectedProvider else { return false }
        return connectionStore.accounts.contains { $0.providerID == provider.providerID }
    }

    private var stepCaption: String? {
        switch step {
        case .pickProvider:
            return "Tap a provider to continue."
        case .authMethod:
            guard let descriptor = selectedProvider.flatMap({ ProviderSetupGuide.registryDescriptor(for: $0) }) else {
                return nil
            }
            return "Choose how you want to authenticate \(descriptor.displayName)."
        case .syncMode:
            return "Where should we run the connection?"
        case .credential:
            return selectedProvider.map(ProviderSetupGuide.registryEnrichedGuide(for:))?.oneLineHint
        default:
            return nil
        }
    }

    // MARK: - Step 1: Pick Provider

    private var pickProviderStep: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                TextField("Search providers", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("a11y.wizard.search.field")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
            )

            providerGridSection(title: "Top picks", providers: filteredRecommended)
            providerGridSection(title: "All providers", providers: filteredOthers)

            if isSearchEmptyOfResults {
                emptySearchState
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    private var isSearchEmptyOfResults: Bool {
        !searchText.isEmpty && filteredRecommended.isEmpty && filteredOthers.isEmpty
    }

    private var emptySearchState: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No providers match \u{201C}\(searchText)\u{201D}.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("Try a shorter search or clear the field to see every supported provider.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
            Button {
                Haptics.selection()
                searchText = ""
            } label: {
                Label("Clear search", systemImage: "xmark.circle.fill")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MobileTheme.Colors.accent)
            .padding(.top, MobileTheme.Spacing.xs)
            .accessibilityIdentifier("a11y.wizard.search.clear")
        }
        .frame(maxWidth: .infinity)
        .padding(MobileTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
        .accessibilityIdentifier("a11y.wizard.search.empty")
    }

    private var allConnectableProviders: [AgentProvider] {
        ProviderSetupGuide.sortedProvidersForOnboarding()
    }

    private var filteredRecommended: [AgentProvider] {
        let recommended = ProviderSetupGuide.recommended.filter(allConnectableProviders.contains(_:))
        guard !searchText.isEmpty else { return recommended }
        return recommended.filter(matchesSearch)
    }

    private var filteredOthers: [AgentProvider] {
        let others = allConnectableProviders.filter { !ProviderSetupGuide.recommended.contains($0) }
        guard !searchText.isEmpty else { return others }
        return others.filter(matchesSearch)
    }

    private func matchesSearch(_ provider: AgentProvider) -> Bool {
        let needle = searchText.lowercased()
        return provider.displayName.lowercased().contains(needle)
            || provider.persistedToken.contains(needle)
            || (ProviderSetupGuide.registryDescriptor(for: provider)?.summary.lowercased().contains(needle) ?? false)
    }

    @ViewBuilder
    private func providerGridSection(title: String, providers: [AgentProvider]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text(title)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: MobileTheme.Spacing.sm),
                        GridItem(.flexible(), spacing: MobileTheme.Spacing.sm)
                    ],
                    spacing: MobileTheme.Spacing.sm
                ) {
                    ForEach(providers, id: \.id) { provider in
                        let descriptorChips = ProviderSetupGuide.capabilityChips(for: provider)
                        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
                        let alreadyConnected = connectionStore.accounts.contains { $0.providerID == provider.providerID }
                        MobileProviderWizardTile(
                            provider: provider,
                            capabilityChips: descriptorChips,
                            oneLineHint: guide.oneLineHint,
                            isSelected: selectedProvider == provider,
                            isAlreadyConnected: alreadyConnected,
                            isRecommended: ProviderSetupGuide.recommended.contains(provider),
                            onTap: {
                                advanceFromPicker(to: provider)
                            }
                        )
                        .accessibilityIdentifier("a11y.wizard.providerTile.\(provider.persistedToken)")
                    }
                }
            }
        }
    }

    private func advanceFromPicker(to provider: AgentProvider) {
        Haptics.selection()
        selectedProvider = provider
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        accountLabel = guide.labelSuggestion
        syncMode = Self.defaultSyncMode(for: guide)
        credential = ""
        runnerURL = ""
        runnerSecret = ""
        errorMessage = nil
        selectedAuthMethodID = ProviderSetupGuide.registryDescriptor(for: provider)?.primaryMethod.id
        advance(to: nextStepAfterPicker(for: provider))
    }

    // MARK: - Step 2: Auth Method

    private var authMethodStep: some View {
        let descriptor = selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            if let descriptor, let provider = selectedProvider {
                MobileProviderConfirmHero(
                    provider: provider,
                    title: descriptor.displayName,
                    subtitle: descriptor.summary,
                    capabilityChips: ProviderSetupGuide.capabilityChips(for: provider),
                    maskedCredential: nil
                )

                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    ForEach(descriptor.methods, id: \.id) { method in
                        MobileAuthMethodCard(
                            method: method,
                            provider: provider,
                            isSelected: selectedAuthMethodID == method.id,
                            onTap: {
                                Haptics.selection()
                                selectedAuthMethodID = method.id
                            }
                        )
                        .accessibilityIdentifier("a11y.wizard.authMethodCard.\(method.id)")
                    }
                }
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    // MARK: - Step 3: Sync Mode

    private var syncModeStep: some View {
        let provider = selectedProvider ?? .openAI
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            MobileProviderConfirmHero(
                provider: provider,
                title: provider.displayName,
                subtitle: guide.oneLineHint,
                capabilityChips: ProviderSetupGuide.capabilityChips(for: provider),
                maskedCredential: nil
            )

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                if guide.supportsHosted {
                    MobileSyncModeCard(
                        mode: .hosted,
                        provider: provider,
                        isSelected: syncMode == .hosted,
                        onTap: {
                            Haptics.selection()
                            syncMode = .hosted
                        }
                    )
                    .accessibilityIdentifier("a11y.wizard.syncModeCard.hosted")
                }
                if guide.supportsSelfHosted {
                    MobileSyncModeCard(
                        mode: .selfHosted,
                        provider: provider,
                        isSelected: syncMode == .selfHosted,
                        onTap: {
                            Haptics.selection()
                            syncMode = .selfHosted
                        }
                    )
                    .accessibilityIdentifier("a11y.wizard.syncModeCard.selfHosted")
                }
                MobileSyncModeCard(
                    mode: .cloud,
                    provider: provider,
                    isSelected: syncMode == .cloud,
                    onTap: {
                        Haptics.selection()
                        syncMode = .cloud
                    }
                )
                .accessibilityIdentifier("a11y.wizard.syncModeCard.cloud")
            }

            if syncMode == .hosted, guide.supportsHosted {
                hostedSubscriptionCard
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    private var hostedSubscriptionCard: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack {
                    Label(
                        subscriptionStore.isActive ? "Hosted Quota Sync active" : "Hosted Quota Sync required",
                        systemImage: subscriptionStore.isActive ? "checkmark.seal.fill" : "lock.fill"
                    )
                    .foregroundStyle(subscriptionStore.isActive ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
                    Spacer()
                    if subscriptionStore.isLoading {
                        MiningPickLoader(.inline)
                    } else if !subscriptionStore.isActive {
                        Button("Subscribe") {
                            Task { await subscriptionStore.purchase() }
                        }
                    }
                }
                if let product = subscriptionStore.product, !subscriptionStore.isActive {
                    Text("\(product.displayPrice) per month")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Button {
                    Task { await subscriptionStore.restorePurchases() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                        .font(MobileTheme.Typography.caption)
                }
                .disabled(subscriptionStore.isLoading)
            }
        }
    }

    // MARK: - Step 4: Credential Entry

    private var credentialStep: some View {
        let provider = selectedProvider ?? .openAI
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        let descriptor = ProviderSetupGuide.registryDescriptor(for: provider)
        let method: BurnBarProviderAuthMethod? = {
            if let id = selectedAuthMethodID, let m = descriptor?.method(id: id) { return m }
            return descriptor?.primaryMethod
        }()

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            MobileProviderConfirmHero(
                provider: provider,
                title: provider.displayName,
                subtitle: method?.summary ?? guide.oneLineHint,
                capabilityChips: ProviderSetupGuide.capabilityChips(for: provider),
                maskedCredential: nil
            )

            // Account label
            VStack(alignment: .leading, spacing: 6) {
                Text("Account label")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField(guide.labelSuggestion, text: $accountLabel)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($labelFocused)
                    .submitLabel(.next)
                    .onSubmit { credentialFocused = true }
                Text("Helps you tell multiple \(provider.displayName) accounts apart.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            if syncMode == .selfHosted {
                selfHostedRunnerFields(provider: provider)
            } else {
                credentialFields(guide: guide, method: method, provider: provider)
            }

            if let dashboardURL = guide.dashboardURL {
                Link(destination: dashboardURL) {
                    Label(guide.dashboardCTA, systemImage: "arrow.up.right.square.fill")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.primary(for: provider))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(MobileTheme.Colors.primary(for: provider).opacity(0.12))
                        )
                }
            }

            if let errorMessage {
                Label {
                    Text(errorMessage)
                        .font(MobileTheme.Typography.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .foregroundStyle(MobileTheme.Colors.error)
                .padding(MobileTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .fill(MobileTheme.Colors.error.opacity(0.08))
                )
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
        .onAppear {
            if accountLabel.isEmpty { accountLabel = guide.labelSuggestion }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                credentialFocused = true
            }
        }
    }

    private func credentialFields(
        guide: ProviderSetupGuide,
        method: BurnBarProviderAuthMethod?,
        provider: AgentProvider
    ) -> some View {
        let validation: BurnBarProviderAuthValidation = {
            if let method { return method.validate(credential) }
            return ProviderSetupGuide.registryValidation(credential: credential, for: provider)
        }()

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Credential")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .tracking(0.6)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Spacer()
                    Button {
                        revealCredential.toggle()
                        Haptics.light()
                    } label: {
                        Image(systemName: revealCredential ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Group {
                    if revealCredential {
                        TextField(guide.credentialPlaceholder, text: $credential, axis: .vertical)
                            .lineLimit(2...4)
                    } else {
                        SecureField(guide.credentialPlaceholder, text: $credential)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($credentialFocused)
                .submitLabel(.go)
                .onSubmit {
                    if canConnect {
                        Task { await connect() }
                    }
                }

                HStack(spacing: 8) {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first {
                            Haptics.success()
                            credential = first
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 36)

                    if !credential.isEmpty {
                        Button {
                            credential = ""
                            Haptics.light()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            MobileValidationChip(validation: validation)

            Text(.init(guide.credentialFooterMarkdown))
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selfHostedRunnerFields(provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runner URL")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField("https://your-runner.run.app", text: $runnerURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !runnerURL.isEmpty, SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) == nil {
                    Label("Use HTTPS, or http://localhost / http://127.0.0.1 for testing.", systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.warning)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Access secret (optional)")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                SecureField("Secret", text: $runnerSecret)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Text("Your runner handles \(provider.displayName) authentication. This device only stores the runner URL and an optional secret.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 5: Connecting

    private var connectingStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            MiningPickLoader(.panel)
                .padding(.top, MobileTheme.Spacing.xxl)
            Text("Connecting to \(selectedProvider?.displayName ?? "provider")…")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("This usually takes a few seconds.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xxl)
    }

    // MARK: - Step 6: Connected

    private var connectedStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            if let provider = selectedProvider {
                MobileProviderConfirmHero(
                    provider: provider,
                    title: "\(provider.displayName) connected",
                    subtitle: connectedAccount.map { "Account: \($0.label)" } ?? "Account is ready to use.",
                    capabilityChips: ProviderSetupGuide.capabilityChips(for: provider),
                    maskedCredential: mobileMaskCredential(credential)
                )
            }

            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
                    .symbolEffect(.bounce)
            }
            .padding(.top, MobileTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xxl)
        .onAppear { Haptics.success() }
    }

    // MARK: - Step 7: Failed

    private var failedStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.error.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.error)
            }
            .padding(.top, MobileTheme.Spacing.xl)

            Text("Couldn't connect")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            if let errorMessage {
                Text(errorMessage)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let provider = selectedProvider,
               let dashboardURL = ProviderSetupGuide.registryEnrichedGuide(for: provider).dashboardURL {
                Link(destination: dashboardURL) {
                    Label(ProviderSetupGuide.registryEnrichedGuide(for: provider).dashboardCTA, systemImage: "arrow.up.right.square.fill")
                        .font(MobileTheme.Typography.caption)
                }
                .foregroundStyle(MobileTheme.Colors.primary(for: provider))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xl)
        .onAppear { Haptics.error() }
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var primaryActionBar: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            switch step {
            case .pickProvider:
                Button("Cancel", action: handleCancel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.cancel")

            case .authMethod:
                primaryButton(title: "Continue", systemImage: "arrow.right") {
                    advanceFromAuthMethod()
                }
                .accessibilityIdentifier("a11y.wizard.continueAuthMethod")
                Button("Back") { advance(to: .pickProvider) }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromAuthMethod")

            case .syncMode:
                primaryButton(
                    title: "Continue",
                    systemImage: "arrow.right",
                    isEnabled: canContinueFromSyncMode
                ) {
                    advance(to: .credential)
                }
                .accessibilityIdentifier("a11y.wizard.continueSyncMode")
                if syncMode == .hosted && !subscriptionStore.isActive {
                    Text("Subscribe to Hosted Quota Sync to continue.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.warning)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("a11y.wizard.hostedRequired")
                }
                Button("Back") { backFromSyncMode() }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromSyncMode")

            case .credential:
                primaryButton(
                    title: isConnecting ? "Connecting…" : "Connect",
                    systemImage: "checkmark.circle.fill",
                    isEnabled: canConnect && !isConnecting
                ) {
                    startConnect()
                }
                .accessibilityIdentifier("a11y.wizard.connect")
                Button("Back") { backFromCredential() }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromCredential")

            case .connecting:
                Button("Cancel", action: cancelConnectingFromUser)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.cancelConnecting")

            case .connected:
                primaryButton(title: "Done", systemImage: "checkmark") {
                    if let connectedAccount {
                        onConnected(connectedAccount)
                    } else {
                        onCancel()
                    }
                }
                .accessibilityIdentifier("a11y.wizard.done")

            case .failed:
                primaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                    advance(to: .credential)
                }
                .accessibilityIdentifier("a11y.wizard.retry")
                Button("Cancel", action: handleCancel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.cancelFromFailed")
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .background(
            MobileTheme.Colors.surface.opacity(0.6)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        )
    }

    /// Sync-mode continue is only valid when the picked mode is reachable.
    /// Hosted requires an active subscription — without this gate the user
    /// could land on the credential step in a state where `canConnect` is
    /// permanently false, leaving them stuck without explanation.
    private var canContinueFromSyncMode: Bool {
        switch syncMode {
        case .cloud, .selfHosted: return true
        case .hosted: return subscriptionStore.isActive
        }
    }

    private func primaryButton(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                if isConnecting && step == .connecting {
                    MiningPickLoader(.inline, tint: .white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .font(MobileTheme.Typography.body)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MobileTheme.Spacing.md)
            .background(
                Capsule()
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(
                              colors: [tintColor, tintColor.opacity(0.7)],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing))
                          : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.4))
                    )
            )
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    private func advance(to next: WizardStep) {
        stepDirection = next.orderIndex >= step.orderIndex ? .forward : .backward
        Haptics.selection()
        withAnimation(MobileTheme.Animation.gentle) {
            step = next
            errorMessage = nil
        }
    }

    private func advanceFromAuthMethod() {
        guard let provider = selectedProvider else { return }
        advance(to: nextStepAfterPicker(for: provider, skipping: .authMethod))
    }

    private func backFromSyncMode() {
        guard let provider = selectedProvider else {
            advance(to: .pickProvider)
            return
        }
        advance(to: hasMultipleAuthMethods(for: provider) ? .authMethod : .pickProvider)
    }

    private func backFromCredential() {
        guard let provider = selectedProvider else {
            advance(to: .pickProvider)
            return
        }
        if ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            advance(to: .syncMode)
        } else if hasMultipleAuthMethods(for: provider) {
            advance(to: .authMethod)
        } else {
            advance(to: .pickProvider)
        }
    }

    /// Single source of truth for "where do we land after the provider picker
    /// (or auth method) for this provider?" — used by init, advance handlers,
    /// and back handlers so they cannot drift apart.
    private func nextStepAfterPicker(
        for provider: AgentProvider,
        skipping skipped: WizardStep? = nil
    ) -> WizardStep {
        if hasMultipleAuthMethods(for: provider) && skipped != .authMethod {
            return .authMethod
        }
        if ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            return .syncMode
        }
        return .credential
    }

    private func hasMultipleAuthMethods(for provider: AgentProvider) -> Bool {
        (ProviderSetupGuide.registryDescriptor(for: provider)?.methods.count ?? 0) > 1
    }

    private func handleCancel() {
        connectTask?.cancel()
        connectTask = nil
        onCancel()
    }

    private func startConnect() {
        connectTask?.cancel()
        connectTask = Task { await connect() }
    }

    /// Called when the user taps Cancel on the `.connecting` step. Pre-fix this
    /// only flipped `isConnecting = false` and bounced back to `.credential`,
    /// while the network request kept running and could persist a credential
    /// server-side after the user had already "cancelled" — silent and bad.
    /// Now we cancel the task handle so the in-flight call honors cooperative
    /// cancellation.
    private func cancelConnectingFromUser() {
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
        advance(to: .credential)
    }

    // MARK: - Connect

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLabel: String {
        accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        guard let provider = selectedProvider, !isConnecting else { return false }
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        switch syncMode {
        case .cloud:
            return ProviderSetupGuide.registryValidation(credential: credential, for: provider) != .empty
                && trimmedCredential.count >= 8
        case .hosted:
            return guide.supportsHosted
                && subscriptionStore.isActive
                && trimmedCredential.count >= 8
        case .selfHosted:
            return SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) != nil
        }
    }

    private var resolvedCredentialKind: CredentialKind {
        guard let provider = selectedProvider,
              let descriptor = ProviderSetupGuide.registryDescriptor(for: provider),
              let id = selectedAuthMethodID,
              let method = descriptor.method(id: id) else {
            return selectedProvider.map { ProviderSetupGuide.guide(for: $0).defaultKind } ?? .token
        }
        switch method.kind {
        case .apiKey: return .token
        case .bearerToken: return .bearer
        case .sessionToken: return .session
        case .cookie: return .cookie
        case .browserLogin, .localRuntime: return .session
        }
    }

    private func connect() async {
        guard let provider = selectedProvider, canConnect else { return }
        Haptics.medium()
        advance(to: .connecting)
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        let labelToUse = trimmedLabel.isEmpty ? guide.labelSuggestion : trimmedLabel
        let kind: CredentialKind = resolvedCredentialKind
        let created: ProviderAccountDoc?

        switch syncMode {
        case .cloud:
            created = await connectionStore.connect(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: kind,
                label: labelToUse
            )
            if Task.isCancelled { return }
        case .hosted:
            do {
                try await subscriptionStore.refreshEntitlement()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                advance(to: .failed)
                return
            }
            if Task.isCancelled { return }
            guard subscriptionStore.isActive else {
                errorMessage = "Hosted Quota Sync subscription is not active."
                advance(to: .failed)
                return
            }
            created = await connectionStore.connectHosted(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: kind,
                label: labelToUse
            )
            if Task.isCancelled { return }
        case .selfHosted:
            created = await connectionStore.connectSelfHosted(
                providerID: provider.providerID,
                label: labelToUse
            )
            if Task.isCancelled {
                if let created { await connectionStore.delete(account: created) }
                return
            }
            if let created {
                do {
                    try SelfHostedQuotaRunnerStore.shared.save(
                        accountID: created.id,
                        runnerURL: runnerURL,
                        accessSecret: runnerSecret.isEmpty ? nil : runnerSecret
                    )
                } catch {
                    SelfHostedQuotaRunnerStore.shared.delete(accountID: created.id)
                    await connectionStore.delete(account: created)
                    errorMessage = error.localizedDescription
                    advance(to: .failed)
                    return
                }
            }
        }

        if Task.isCancelled { return }
        if let created {
            connectedAccount = created
            advance(to: .connected)
        } else {
            errorMessage = connectionStore.error ?? "We couldn't validate your credentials."
            advance(to: .failed)
        }
    }
}

// MARK: - Previews

#Preview("Picker (no preselected)") {
    NavigationStack {
        MobileProviderWizardView(
            preselectedProvider: nil,
            onConnected: { _ in },
            onCancel: { }
        )
        .navigationTitle("Add provider")
        .navigationBarTitleDisplayMode(.inline)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }
}

#Preview("MiniMax (multi-method)") {
    NavigationStack {
        MobileProviderWizardView(
            preselectedProvider: .minimax,
            onConnected: { _ in },
            onCancel: { }
        )
        .navigationTitle("Add MiniMax")
        .navigationBarTitleDisplayMode(.inline)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }
}

#Preview("Codex (hosted/self-hosted)") {
    NavigationStack {
        MobileProviderWizardView(
            preselectedProvider: .codex,
            onConnected: { _ in },
            onCancel: { }
        )
        .navigationTitle("Add Codex")
        .navigationBarTitleDisplayMode(.inline)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }
}
