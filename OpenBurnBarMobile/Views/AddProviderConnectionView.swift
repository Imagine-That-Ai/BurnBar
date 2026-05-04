import SwiftUI
import OpenBurnBarCore

struct AddProviderConnectionView: View {
    let provider: AgentProvider

    @State private var accountLabel = ""
    @State private var credential = ""
    @State private var selectedKind: CredentialKind = .token
    @State private var syncMode: QuotaConnectionMode = .cloud
    @State private var runnerURL = ""
    @State private var runnerAccessSecret = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var labelFocused: Bool
    @FocusState private var credentialFocused: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var connectionStore = ProviderConnectionStore()
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLabel: String {
        accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return supportsHostedQuotaRunner && subscriptionStore.isActive && validationState == .valid
        case .selfHosted:
            return SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) != nil
        }
    }

    private var supportsRemoteQuotaRunner: Bool {
        provider.providerID == .claudeCode || provider.providerID == .codex
    }

    private var supportsHostedQuotaRunner: Bool {
        provider.providerID == .codex
    }

    var body: some View {
        NavigationStack {
            Form {
                providerHeaderSection
                syncModeSection
                hostedSubscriptionSection
                accountLabelSection
                credentialSection
                selfHostedRunnerSection
                expirationWarningSection
                errorSection
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConnecting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canConnect)
                    .accessibilityLabel(isConnecting ? "Connecting" : "Connect account")
                }
            }
            .onAppear {
                if supportsRemoteQuotaRunner {
                    syncMode = .hosted
                    selectedKind = provider.providerID == .codex ? .session : .bearer
                    if !supportsHostedQuotaRunner {
                        syncMode = .selfHosted
                    }
                }
                // Focus the label field first so multi-account naming feels
                // intentional. Users who already have a default account
                // typically want to differentiate the new one.
                if accountLabel.isEmpty { labelFocused = true }
            }
            .task {
                if supportsHostedQuotaRunner {
                    await subscriptionStore.load()
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var providerHeaderSection: some View {
        Section {
            HStack(spacing: MobileTheme.Spacing.md) {
                ProviderAvatar(provider: provider, mode: .aurora, size: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(providerHeaderSubtitle)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var providerHeaderSubtitle: String {
        if supportsRemoteQuotaRunner {
            if supportsHostedQuotaRunner {
                return "Add quota sync without opening the Mac app."
            }
            return "Self-hosted only. Your runner handles authentication; this device stores only the runner URL and an optional secret."
        }
        return "Add an account to refresh quota and attribute usage."
    }

    @ViewBuilder
    private var syncModeSection: some View {
        if supportsRemoteQuotaRunner {
            Section {
                if supportsHostedQuotaRunner {
                    Picker("Sync", selection: $syncMode) {
                        Label("Hosted", systemImage: "cloud").tag(QuotaConnectionMode.hosted)
                        Label("Self-hosted", systemImage: "server.rack").tag(QuotaConnectionMode.selfHosted)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: MobileTheme.Spacing.md) {
                        Image(systemName: syncMode == .hosted ? "cloud.fill" : "server.rack")
                            .font(.system(size: 18))
                            .foregroundStyle(syncMode == .hosted ? MobileTheme.whimsy : MobileTheme.amber)
                            .accessibilityHidden(true)
                        Text(syncMode == .hosted
                             ? "Credentials stored server-side. Quota refreshes on request."
                             : "Credentials stay on your runner. Sanitized snapshots only.")
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                } else {
                    HStack(spacing: MobileTheme.Spacing.md) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 24))
                            .foregroundStyle(MobileTheme.Colors.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Self-hosted runner")
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text("Configure auth in your own runner. This device never receives \(provider.displayName) credentials.")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text(syncMode.footerText(provider: provider.displayName))
                    .font(MobileTheme.Typography.caption)
            }
        }
    }

    @ViewBuilder
    private var hostedSubscriptionSection: some View {
        if supportsHostedQuotaRunner, syncMode == .hosted {
            Section {
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
                if let error = subscriptionStore.error {
                    Text(error)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.error)
                }
            } footer: {
                Text("Hosted sync refreshes quota only when you tap refresh. You can delete hosted credentials at any time.")
                    .font(MobileTheme.Typography.caption)
            }
        }
    }

    @ViewBuilder
    private var accountLabelSection: some View {
        Section {
            TextField("Label", text: $accountLabel, prompt: Text("e.g. Work, Personal, Client"))
                .textContentType(.nickname)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .focused($labelFocused)
                .submitLabel(.next)
                .onSubmit { credentialFocused = true }
        } header: {
            Text("Account label")
        } footer: {
            Text("Helps you tell multiple \(provider.displayName) accounts apart.")
                .font(MobileTheme.Typography.caption)
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
        if syncMode != .selfHosted {
            Section {
                Picker("Credential type", selection: $selectedKind) {
                    Text("Token").tag(CredentialKind.token)
                    Text("Bearer").tag(CredentialKind.bearer)
                    Text("Session").tag(CredentialKind.session)
                    Text("Cookie").tag(CredentialKind.cookie)
                    Text("Plan").tag(CredentialKind.plan)
                }
                .pickerStyle(.menu)

                SecureField("Paste your credential", text: $credential)
                    .font(MobileTheme.Typography.body)
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
                        credential = first
                    }
                }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Paste credential")
            } header: {
                Text("Credential")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if validationState == .tooShort {
                        Text("That looks too short. Make sure you copied the full credential.")
                            .foregroundStyle(MobileTheme.Colors.warning)
                    } else {
                        Text(credentialFooterText)
                    }
                }
                .font(MobileTheme.Typography.caption)
            }
        }
    }

    @ViewBuilder
    private var selfHostedRunnerSection: some View {
        if supportsRemoteQuotaRunner, syncMode == .selfHosted {
            Section {
                TextField("Runner URL", text: $runnerURL, prompt: Text("https://your-runner.run.app"))
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if !runnerURL.isEmpty, SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) == nil {
                    Label("Use HTTPS, or http://localhost and http://127.0.0.1 for testing.", systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.warning)
                }

                SecureField("Access secret (optional)", text: $runnerAccessSecret)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Self-hosted runner")
            } footer: {
                Text(selfHostedFooterText)
                    .font(MobileTheme.Typography.caption)
            }
        }
    }

    private var selfHostedFooterText: String {
        switch provider.providerID {
        case .claudeCode:
            return "Your runner handles Claude Code authentication. Only the runner URL and optional secret are stored on this device."
        case .codex:
            return "Your runner handles Codex authentication. Only the runner URL and optional secret are stored on this device."
        default:
            return "Use HTTPS for deployed runners, or localhost for testing. Sanitized quota snapshots are uploaded after each refresh."
        }
    }

    @ViewBuilder
    private var expirationWarningSection: some View {
        if syncMode != .selfHosted, selectedKind == .session || selectedKind == .cookie {
            Section {
                Label {
                    Text("Session and cookie credentials may expire. Reconnect if quota refresh stops working.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.warning)
            }
        }
    }

    private var credentialFooterText: String {
        if syncMode == .hosted {
            return "Paste the contents of your Codex auth.json. OpenBurnBar stores it server-side for explicit hosted quota refreshes."
        }
        return "OpenBurnBar uses this to add the quota account and enable cloud refresh where the provider supports it."
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                Label {
                    Text(errorMessage)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.error)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(MobileTheme.Colors.error)
                }
            }
        }
    }

    private func connect() async {
        guard canConnect else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let created: ProviderAccountDoc?
        switch syncMode {
        case .cloud:
            created = await connectionStore.connect(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: selectedKind,
                label: trimmedLabel.emptyToNil
            )
        case .hosted:
            guard supportsHostedQuotaRunner else {
                errorMessage = "Hosted quota sync is not available for \(provider.displayName). Use a self-hosted runner."
                return
            }
            do {
                try await subscriptionStore.refreshEntitlement()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            guard subscriptionStore.isActive else {
                errorMessage = "Hosted Quota Sync subscription is not active."
                return
            }
            created = await connectionStore.connectHosted(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: selectedKind,
                label: trimmedLabel.emptyToNil
            )
        case .selfHosted:
            created = await connectionStore.connectSelfHosted(
                providerID: provider.providerID,
                label: trimmedLabel.emptyToNil
            )
            if let created {
                do {
                    try SelfHostedQuotaRunnerStore.shared.save(
                        accountID: created.id,
                        runnerURL: runnerURL,
                        accessSecret: runnerAccessSecret.emptyToNil
                    )
                } catch {
                    SelfHostedQuotaRunnerStore.shared.delete(accountID: created.id)
                    await connectionStore.delete(account: created)
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }

        if created != nil {
            dismiss()
        } else {
            errorMessage = connectionStore.error
        }
    }
}

// MARK: - Validation State

private enum ValidationState {
    case empty
    case tooShort
    case valid
}

private enum QuotaConnectionMode: String, Hashable {
    case cloud
    case hosted
    case selfHosted

    func footerText(provider: String) -> String {
        switch self {
        case .cloud:
            return "Use the standard cloud credential path for providers with backend APIs."
        case .hosted:
            return "OpenBurnBar stores provider auth server-side and runs \(provider) quota probes only when requested."
        case .selfHosted:
            return "Use your own runner. OpenBurnBar receives only sanitized quota snapshots, not \(provider) credentials."
        }
    }
}

private extension String {
    var emptyToNil: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    AddProviderConnectionView(provider: .minimax)
}
