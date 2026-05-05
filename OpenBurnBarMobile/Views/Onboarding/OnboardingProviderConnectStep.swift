import SwiftUI
import OpenBurnBarCore

/// Single-provider connect flow used by both the onboarding wizard and the
/// renovated manual sheet. Three internal sub-steps:
///
///     guide → paste → result
///
/// On `result == .connected` the parent decides whether to advance to the
/// next provider in the wizard queue or dismiss the manual sheet.
struct OnboardingProviderConnectStep: View {
    let provider: AgentProvider
    let queuePosition: QueuePosition?
    let onConnected: (ProviderAccountDoc) -> Void
    let onSkip: () -> Void

    /// Optional contextual hint shown above the title — e.g. "3 of 5 · Cursor".
    struct QueuePosition: Hashable {
        let current: Int
        let total: Int
    }

    @State private var subStep: SubStep = .guide
    @State private var accountLabel: String = ""
    @State private var credential: String = ""
    @State private var selectedKind: CredentialKind
    @State private var syncMode: QuotaConnectionMode
    @State private var runnerURL: String = ""
    @State private var runnerSecret: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var connectedAccount: ProviderAccountDoc?
    @FocusState private var labelFocused: Bool
    @FocusState private var credentialFocused: Bool

    @State private var connectionStore = ProviderConnectionStore()
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()

    init(
        provider: AgentProvider,
        queuePosition: QueuePosition? = nil,
        onConnected: @escaping (ProviderAccountDoc) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.provider = provider
        self.queuePosition = queuePosition
        self.onConnected = onConnected
        self.onSkip = onSkip

        let guide = ProviderSetupGuide.guide(for: provider)
        _selectedKind = State(initialValue: guide.defaultKind)

        // Default to a sensible sync mode based on what the provider supports.
        if guide.supportsHosted {
            _syncMode = State(initialValue: .hosted)
        } else if guide.supportsSelfHosted {
            _syncMode = State(initialValue: .selfHosted)
        } else {
            _syncMode = State(initialValue: .cloud)
        }
    }

    private var guide: ProviderSetupGuide { ProviderSetupGuide.guide(for: provider) }

    enum SubStep: Hashable {
        case guide
        case paste
        case connecting
        case connected
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            subStepHeader

            ScrollView {
                Group {
                    switch subStep {
                    case .guide:      guideStep
                    case .paste:      pasteStep
                    case .connecting: connectingStep
                    case .connected:  connectedStep
                    case .failed:     failedStep
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }

            primaryActionBar
        }
        .animation(MobileTheme.Animation.gentle, value: subStep)
        .task {
            if guide.supportsHosted {
                await subscriptionStore.load()
            }
        }
    }

    // MARK: - Header (queue position + sub-step dots)

    private var subStepHeader: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                ProviderAvatar(provider: provider, mode: .aurora, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    if let queuePosition {
                        Text("\(queuePosition.current) of \(queuePosition.total) · \(provider.displayName)")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Text(subStepTitle)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }
                Spacer()
                stepDots
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .background(MobileTheme.Colors.surface.opacity(0.6))
    }

    private var subStepTitle: String {
        switch subStep {
        case .guide:      return "Where to find it"
        case .paste:      return "Paste your credential"
        case .connecting: return "Connecting…"
        case .connected:  return "You're connected"
        case .failed:     return "Couldn't connect"
        }
    }

    private var stepDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(dotFill(for: index))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func dotFill(for index: Int) -> Color {
        let activeIndex: Int
        switch subStep {
        case .guide:      activeIndex = 0
        case .paste:      activeIndex = 1
        case .connecting: activeIndex = 2
        case .connected:  activeIndex = 2
        case .failed:     activeIndex = 1
        }
        return index <= activeIndex
            ? MobileTheme.Colors.primary(for: provider)
            : MobileTheme.Colors.border
    }

    // MARK: - Step 1: Guide

    private var guideStep: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            // Hero
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text(guide.oneLineHint)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let dashboardURL = guide.dashboardURL {
                    Link(destination: dashboardURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square.fill")
                            Text(guide.dashboardCTA)
                                .fontWeight(.semibold)
                        }
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.primary(for: provider))
                    }
                    .accessibilityHint("Opens \(provider.displayName) in Safari.")
                }
            }

            // Sync-mode picker (Codex hosted/self-hosted, Claude Code self-hosted only).
            if guide.supportsRemoteRunner {
                syncModePicker
            }

            // Numbered instructions.
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                ForEach(guide.instructions) { step in
                    GuideStepRow(step: step, tint: MobileTheme.Colors.primary(for: provider))
                }
            }

            // Hosted subscription gate (Codex only).
            if guide.supportsHosted, syncMode == .hosted {
                hostedSubscriptionCard
            }
        }
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    private var syncModePicker: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("Sync mode")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .tracking(0.6)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Picker("Sync", selection: $syncMode) {
                if guide.supportsHosted {
                    Label("Hosted", systemImage: "cloud").tag(QuotaConnectionMode.hosted)
                }
                if guide.supportsSelfHosted {
                    Label("Self-hosted", systemImage: "server.rack").tag(QuotaConnectionMode.selfHosted)
                }
            }
            .pickerStyle(.segmented)

            Text(syncMode.description(provider: provider.displayName))
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                        ProgressView()
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

    // MARK: - Step 2: Paste

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            // Account label first — multi-account naming feels intentional.
            VStack(alignment: .leading, spacing: 6) {
                Text("Account label")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField("Label", text: $accountLabel, prompt: Text(guide.labelSuggestion))
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

            // Self-hosted runner inputs.
            if syncMode == .selfHosted {
                selfHostedRunnerFields
            } else {
                credentialFields
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
            if accountLabel.isEmpty { labelFocused = true }
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Credential")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .tracking(0.6)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Spacer()
                    if guide.kinds.count > 1 {
                        Picker("Type", selection: $selectedKind) {
                            ForEach(guide.kinds, id: \.self) { kind in
                                Text(ProviderSetupGuide.credentialKindLabel(kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(MobileTheme.Colors.primary(for: provider))
                    }
                }

                SecureField(guide.credentialPlaceholder, text: $credential)
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

                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first {
                        Haptics.success()
                        credential = first
                    }
                }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            Text(.init(guide.credentialFooterMarkdown))
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if validationState == .tooShort {
                Label("That looks too short — make sure you copied the full credential.", systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.warning)
            }
        }
    }

    private var selfHostedRunnerFields: some View {
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

    // MARK: - Step 3: Connecting / Result

    private var connectingStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .padding(.top, MobileTheme.Spacing.xxl)
            Text("Connecting to \(provider.displayName)…")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("This usually takes a few seconds.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xxl)
    }

    private var connectedStep: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
                    .symbolEffect(.bounce)
            }
            .padding(.top, MobileTheme.Spacing.xl)

            Text("\(provider.displayName) connected")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            if let connectedAccount {
                Text("Account: \(connectedAccount.label)")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xxl)
        .onAppear { Haptics.success() }
    }

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

            if let dashboardURL = guide.dashboardURL {
                Link(destination: dashboardURL) {
                    Label(guide.dashboardCTA, systemImage: "arrow.up.right.square.fill")
                        .font(MobileTheme.Typography.caption)
                }
                .foregroundStyle(MobileTheme.Colors.primary(for: provider))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, MobileTheme.Spacing.xl)
        .onAppear { Haptics.error() }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var primaryActionBar: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            switch subStep {
            case .guide:
                primaryButton(title: "I have it", systemImage: "arrow.right") {
                    advance(to: .paste)
                }
                Button("Skip \(provider.displayName) for now", action: onSkip)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

            case .paste:
                primaryButton(
                    title: isConnecting ? "Connecting…" : "Connect",
                    systemImage: "checkmark.circle.fill",
                    isEnabled: canConnect && !isConnecting
                ) {
                    Task { await connect() }
                }
                Button("Back") {
                    advance(to: .guide)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            case .connecting:
                Button("Cancel") {
                    isConnecting = false
                    advance(to: .paste)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            case .connected:
                primaryButton(title: "Continue", systemImage: "arrow.right") {
                    if let connectedAccount {
                        onConnected(connectedAccount)
                    }
                }

            case .failed:
                primaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                    advance(to: .paste)
                }
                Button("Skip \(provider.displayName)", action: onSkip)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
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
                if isConnecting && subStep != .connected {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(MobileTheme.Typography.body)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MobileTheme.Spacing.md)
            .background(
                Capsule()
                    .fill(isEnabled ? AnyShapeStyle(MobileTheme.primaryGradient) : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.4)))
            )
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }

    // MARK: - State helpers

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLabel: String {
        accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum ValidationState {
        case empty, tooShort, valid
    }

    private var validationState: ValidationState {
        if trimmedCredential.isEmpty { return .empty }
        if trimmedCredential.count < 8 { return .tooShort }
        return .valid
    }

    private var canConnect: Bool {
        guard !isConnecting else { return false }
        switch syncMode {
        case .cloud:
            return validationState == .valid
        case .hosted:
            return guide.supportsHosted && subscriptionStore.isActive && validationState == .valid
        case .selfHosted:
            return SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) != nil
        }
    }

    private func advance(to next: SubStep) {
        Haptics.selection()
        withAnimation(MobileTheme.Animation.gentle) {
            subStep = next
            errorMessage = nil
        }
    }

    private func connect() async {
        guard canConnect else { return }
        Haptics.medium()
        advance(to: .connecting)
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let labelToUse = trimmedLabel.isEmpty ? guide.labelSuggestion : trimmedLabel
        let created: ProviderAccountDoc?

        switch syncMode {
        case .cloud:
            created = await connectionStore.connect(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: selectedKind,
                label: labelToUse
            )
        case .hosted:
            do {
                try await subscriptionStore.refreshEntitlement()
            } catch {
                errorMessage = error.localizedDescription
                advance(to: .failed)
                return
            }
            guard subscriptionStore.isActive else {
                errorMessage = "Hosted Quota Sync subscription is not active."
                advance(to: .failed)
                return
            }
            created = await connectionStore.connectHosted(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: selectedKind,
                label: labelToUse
            )
        case .selfHosted:
            created = await connectionStore.connectSelfHosted(
                providerID: provider.providerID,
                label: labelToUse
            )
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

        if let created {
            connectedAccount = created
            advance(to: .connected)
        } else {
            errorMessage = connectionStore.error ?? "We couldn't validate your credentials."
            advance(to: .failed)
        }
    }
}

// MARK: - Sync mode

enum QuotaConnectionMode: String, Hashable {
    case cloud
    case hosted
    case selfHosted

    func description(provider: String) -> String {
        switch self {
        case .cloud:
            return "Standard cloud credentials. Refreshes from any signed-in device."
        case .hosted:
            return "OpenBurnBar stores \(provider) auth server-side. Quota refreshes only when requested."
        case .selfHosted:
            return "Your runner handles \(provider) auth. We only receive sanitized snapshots."
        }
    }
}

// MARK: - Guide step row

private struct GuideStepRow: View {
    let step: GuideStep
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 28, height: 28)
                Text("\(step.number)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                if let detail = step.detail {
                    Text(detail)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snippet = step.codeSnippet {
                    Text(snippet)
                        .font(MobileTheme.Typography.monoTiny)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(MobileTheme.Colors.surfaceElevated)
                        )
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Cursor") {
    OnboardingProviderConnectStep(
        provider: .cursor,
        queuePosition: .init(current: 1, total: 3),
        onConnected: { _ in },
        onSkip: { }
    )
    .background(EmberSurfaceBackground().ignoresSafeArea())
}

#Preview("Codex (hosted)") {
    OnboardingProviderConnectStep(
        provider: .codex,
        queuePosition: .init(current: 2, total: 3),
        onConnected: { _ in },
        onSkip: { }
    )
    .background(EmberSurfaceBackground().ignoresSafeArea())
}
