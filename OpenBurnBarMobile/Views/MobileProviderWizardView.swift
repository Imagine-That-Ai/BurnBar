import SwiftUI
import OpenBurnBarCore

/// Beautiful card-based provider connect wizard for iOS.
///
/// Thin SwiftUI shell over `MobileProviderWizardModel`. All state-machine
/// logic, navigation, validation, and connect/cancel semantics live in the
/// model so they can be unit-tested without ViewInspector. This view only
/// owns focus state and rendering.
struct MobileProviderWizardView: View {

    @State private var model: MobileProviderWizardModel
    @FocusState private var labelFocused: Bool
    @FocusState private var credentialFocused: Bool

    init(
        preselectedProvider: AgentProvider?,
        onConnected: @escaping (ProviderAccountDoc) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: MobileProviderWizardModel(
            preselectedProvider: preselectedProvider,
            onConnected: onConnected,
            onCancel: onCancel
        ))
    }

    /// Test/preview seam — inject a pre-configured model.
    init(model: MobileProviderWizardModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            wizardHeader

            ScrollView {
                Group {
                    switch m.step {
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
                .id(m.step)
                .transition(.asymmetric(
                    insertion: .move(edge: m.stepDirection == .forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: m.stepDirection == .forward ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .scrollDismissesKeyboard(.interactively)

            primaryActionBar
        }
        .animation(MobileTheme.Animation.gentle, value: m.step)
        .task { await model.bootstrap() }
    }

    // MARK: - Header

    private var wizardHeader: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                if let provider = model.selectedProvider {
                    ProviderAvatar(provider: provider, mode: .aurora, size: 36)
                } else {
                    Image(systemName: "rectangle.stack.fill.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(MobileTheme.Colors.surface))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.stepTitle)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    if let caption = model.stepCaption {
                        Text(caption)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                Spacer()
                MobileWizardProgressDots(
                    total: model.totalDots,
                    active: model.activeDot,
                    tint: tintColor
                )
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .background(MobileTheme.Colors.surface.opacity(0.6))
    }

    private var tintColor: Color {
        guard let provider = model.selectedProvider else { return MobileTheme.Colors.accent }
        return MobileTheme.Colors.primary(for: provider)
    }

    // MARK: - Step 1: Pick Provider

    private var pickProviderStep: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                TextField("Search providers", text: $m.searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("a11y.wizard.search.field")
                if !m.searchText.isEmpty {
                    Button(action: { m.clearSearch() }) {
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

            providerGridSection(title: "Top picks", providers: model.filteredRecommended)
            providerGridSection(title: "All providers", providers: model.filteredOthers)

            if model.isSearchEmptyOfResults {
                emptySearchState
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    private var emptySearchState: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No providers match \u{201C}\(model.searchText)\u{201D}.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("Try a shorter search or clear the field to see every supported provider.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
            Button(action: { model.clearSearch() }) {
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
                        MobileProviderWizardTile(
                            provider: provider,
                            capabilityChips: descriptorChips,
                            oneLineHint: guide.oneLineHint,
                            isSelected: model.selectedProvider == provider,
                            isAlreadyConnected: model.isProviderAlreadyConnected(provider),
                            isRecommended: ProviderSetupGuide.recommended.contains(provider),
                            onTap: { model.advanceFromPicker(to: provider) }
                        )
                        .accessibilityIdentifier("a11y.wizard.providerTile.\(provider.persistedToken)")
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Auth Method

    private var authMethodStep: some View {
        let descriptor = model.selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            if let descriptor, let provider = model.selectedProvider {
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
                            isSelected: model.selectedAuthMethodID == method.id,
                            onTap: { model.selectAuthMethod(method.id) }
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
        let provider = model.selectedProvider ?? .openAI
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
                        isSelected: model.syncMode == .hosted,
                        onTap: { model.selectSyncMode(.hosted) }
                    )
                    .accessibilityIdentifier("a11y.wizard.syncModeCard.hosted")
                }
                if guide.supportsSelfHosted {
                    MobileSyncModeCard(
                        mode: .selfHosted,
                        provider: provider,
                        isSelected: model.syncMode == .selfHosted,
                        onTap: { model.selectSyncMode(.selfHosted) }
                    )
                    .accessibilityIdentifier("a11y.wizard.syncModeCard.selfHosted")
                }
                MobileSyncModeCard(
                    mode: .cloud,
                    provider: provider,
                    isSelected: model.syncMode == .cloud,
                    onTap: { model.selectSyncMode(.cloud) }
                )
                .accessibilityIdentifier("a11y.wizard.syncModeCard.cloud")
            }

            if model.syncMode == .hosted, guide.supportsHosted {
                hostedSubscriptionCard
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    private var hostedSubscriptionCard: some View {
        let concreteStore = model.subscriptionStore as? HostedQuotaSubscriptionStore
        return UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack {
                    Label(
                        model.subscriptionStore.isActive ? "Hosted Quota Sync active" : "Hosted Quota Sync required",
                        systemImage: model.subscriptionStore.isActive ? "checkmark.seal.fill" : "lock.fill"
                    )
                    .foregroundStyle(model.subscriptionStore.isActive ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
                    Spacer()
                    if concreteStore?.isPurchasing == true {
                        MiningPickLoader(.inline)
                    } else if !model.subscriptionStore.isActive, let store = concreteStore {
                        Button("Subscribe") {
                            Task { await store.purchase() }
                        }
                    }
                }
                if let product = concreteStore?.product, !model.subscriptionStore.isActive {
                    Text("\(product.displayPrice) per month")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                if let store = concreteStore {
                    Button {
                        Task { await store.restorePurchases() }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                            .font(MobileTheme.Typography.caption)
                    }
                    .disabled(model.subscriptionStore.isLoading || concreteStore?.isPurchasing == true)
                }
            }
        }
    }

    // MARK: - Step 4: Credential Entry

    private var credentialStep: some View {
        @Bindable var m = model
        let provider = m.selectedProvider ?? .openAI
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        let descriptor = ProviderSetupGuide.registryDescriptor(for: provider)
        let method: BurnBarProviderAuthMethod? = {
            if let id = m.selectedAuthMethodID, let meth = descriptor?.method(id: id) { return meth }
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Account label")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField(guide.labelSuggestion, text: $m.accountLabel)
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

            if m.syncMode == .selfHosted {
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
                            Capsule().fill(MobileTheme.Colors.primary(for: provider).opacity(0.12))
                        )
                }
            }

            if let err = m.errorMessage {
                Label {
                    Text(err).font(MobileTheme.Typography.footnote)
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
            if model.accountLabel.isEmpty { model.accountLabel = guide.labelSuggestion }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { credentialFocused = true }
        }
    }

    private func credentialFields(
        guide: ProviderSetupGuide,
        method: BurnBarProviderAuthMethod?,
        provider: AgentProvider
    ) -> some View {
        @Bindable var m = model
        let validation: BurnBarProviderAuthValidation = {
            if let method { return method.validate(m.credential) }
            return ProviderSetupGuide.registryValidation(credential: m.credential, for: provider)
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
                    Button(action: { m.toggleRevealCredential() }) {
                        Image(systemName: m.revealCredential ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Group {
                    if m.revealCredential {
                        TextField(guide.credentialPlaceholder, text: $m.credential, axis: .vertical)
                            .lineLimit(2...4)
                    } else {
                        SecureField(guide.credentialPlaceholder, text: $m.credential)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($credentialFocused)
                .submitLabel(.go)
                .onSubmit {
                    if model.canConnect { model.startConnect() }
                }

                HStack(spacing: 8) {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first {
                            model.haptics.success()
                            model.credential = first
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 36)

                    if !m.credential.isEmpty {
                        Button {
                            m.credential = ""
                            model.haptics.light()
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
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runner URL")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField("https://your-runner.run.app", text: $m.runnerURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !m.runnerURL.isEmpty, SelfHostedQuotaRunnerStore.validatedRunnerURL(m.runnerURL) == nil {
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
                SecureField("Secret", text: $m.runnerSecret)
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
            Text("Connecting to \(model.selectedProvider?.displayName ?? "provider")…")
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
            if let provider = model.selectedProvider {
                MobileProviderConfirmHero(
                    provider: provider,
                    title: "\(provider.displayName) connected",
                    subtitle: model.connectedAccount.map { "Account: \($0.label)" } ?? "Account is ready to use.",
                    capabilityChips: ProviderSetupGuide.capabilityChips(for: provider),
                    maskedCredential: mobileMaskCredential(model.credential)
                )
            }
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
            }
            .padding(.top, MobileTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xxl)
        .onAppear { model.haptics.success() }
    }

    // MARK: - Step 7: Failed

    private var failedStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            ZStack {
                Circle().fill(MobileTheme.Colors.error.opacity(0.18)).frame(width: 96, height: 96)
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.error)
            }
            .padding(.top, MobileTheme.Spacing.xl)

            Text("Couldn't connect")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            if let err = model.errorMessage {
                Text(err)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let provider = model.selectedProvider,
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
        .onAppear { model.haptics.error() }
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var primaryActionBar: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            switch model.step {
            case .pickProvider:
                Button("Cancel", action: { model.handleCancel() })
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.cancel")

            case .authMethod:
                primaryButton(title: "Continue", systemImage: "arrow.right") {
                    model.advanceFromAuthMethod()
                }
                .accessibilityIdentifier("a11y.wizard.continueAuthMethod")
                Button("Back") { model.advance(to: .pickProvider) }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromAuthMethod")

            case .syncMode:
                primaryButton(
                    title: "Continue",
                    systemImage: "arrow.right",
                    isEnabled: model.canContinueFromSyncMode
                ) {
                    model.advance(to: .credential)
                }
                .accessibilityIdentifier("a11y.wizard.continueSyncMode")
                if model.syncMode == .hosted && !model.subscriptionStore.isActive {
                    Text("Subscribe to Hosted Quota Sync to continue.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.warning)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("a11y.wizard.hostedRequired")
                }
                Button("Back") { model.backFromSyncMode() }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromSyncMode")

            case .credential:
                primaryButton(
                    title: model.isConnecting ? "Connecting…" : "Connect",
                    systemImage: "checkmark.circle.fill",
                    isEnabled: model.canConnect && !model.isConnecting
                ) {
                    model.startConnect()
                }
                .accessibilityIdentifier("a11y.wizard.connect")
                Button("Back") { model.backFromCredential() }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.backFromCredential")

            case .connecting:
                Button("Cancel", action: { model.cancelConnectingFromUser() })
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityIdentifier("a11y.wizard.cancelConnecting")

            case .connected:
                primaryButton(title: "Done", systemImage: "checkmark") {
                    if let account = model.connectedAccount {
                        model.onConnected(account)
                    } else {
                        model.onCancel()
                    }
                }
                .accessibilityIdentifier("a11y.wizard.done")

            case .failed:
                primaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                    model.advance(to: .credential)
                }
                .accessibilityIdentifier("a11y.wizard.retry")
                Button("Cancel", action: { model.handleCancel() })
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

    private func primaryButton(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                if model.isConnecting && model.step == .connecting {
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
