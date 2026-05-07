import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

func providerQuotaManagementURL(
    for provider: AgentProvider,
    snapshot: ProviderQuotaSnapshot?
) -> URL? {
    if let link = snapshot?.managementLink {
        return link
    }

    let fallback: String? = switch provider {
    case .codex:
        "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan"
    case .claudeCode:
        "https://code.claude.com/docs/en/statusline"
    case .minimax:
        "https://platform.minimax.io/docs/token-plan/faq"
    case .zai:
        "https://bigmodel.cn/usercenter/glm-coding/usage"
    case .factory:
        "https://app.factory.ai"
    case .cursor:
        "https://cursor.com/pricing"
    default:
        nil
    }

    guard let fallback else { return nil }
    return URL(string: fallback)
}

struct ProviderQuotaSettingsSection: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore
    let onOpenProviderPlans: (AgentProvider) -> Void
    let quotaSourceSummary: (AgentProvider) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Quota reporting stays separate from spend history. OpenBurnBar uses official APIs where they exist and otherwise shows the best verifiable local signal it can: Codex rollout snapshots, Claude statusline JSON, and Factory / Droid monthly token estimates. Review provider-level quota here or in each provider dashboard.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                ProviderQuotaSettingsCard(
                    provider: provider,
                    settingsManager: settingsManager,
                    quotaService: quotaService,
                    dataStore: dataStore,
                    onOpenProviderPlans: onOpenProviderPlans,
                    quotaSourceSummary: quotaSourceSummary(provider)
                )
            }
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }
}

struct ProviderQuotaSmartHubsSection: View {
    @Bindable var settingsManager: SettingsManager

    @State private var refreshStatus: String?
    @State private var isRefreshingHub = false

    private var dashboardURL: URL? {
        URL(string: settingsManager.smartHubQuotaDashboardURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var refreshURL: URL? {
        URL(string: settingsManager.smartHubQuotaRefreshURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var voiceRefreshURL: URL? {
        URL(string: settingsManager.smartHubQuotaVoiceRefreshURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.whimsy.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: "display")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nest Hub quota display")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Expose the provider quota dashboard on a Google Nest Hub or any DashCast-compatible smart display.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: DesignSystem.Spacing.md)

                    Toggle("", isOn: $settingsManager.smartHubQuotaDisplayEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Enable smart hub quota display")
                }

                if settingsManager.smartHubQuotaDisplayEnabled {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        smartHubField(
                            title: "Dashboard URL",
                            text: $settingsManager.smartHubQuotaDashboardURL,
                            placeholder: "http://127.0.0.1:8787/render.html"
                        )

                        smartHubField(
                            title: "Refresh endpoint",
                            text: $settingsManager.smartHubQuotaRefreshURL,
                            placeholder: "http://127.0.0.1:8787/refresh"
                        )

                        smartHubField(
                            title: "Voice routine endpoint",
                            text: $settingsManager.smartHubQuotaVoiceRefreshURL,
                            placeholder: "http://127.0.0.1:8787/voice-refresh"
                        )

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            smartHubProviderChip("Claude", color: DesignSystem.Colors.ember)
                            smartHubProviderChip("Codex", color: DesignSystem.Colors.success)
                            smartHubProviderChip("Cursor", color: .blue)
                            smartHubProviderChip("Droid", color: DesignSystem.Colors.whimsy)
                        }

                        HStack(spacing: DesignSystem.Spacing.md) {
                            GlassButton(title: "Open", icon: "arrow.up.right.square", style: .regular) {
                                openDashboard()
                            }
                            .disabled(dashboardURL == nil)

                            GlassButton(
                                title: isRefreshingHub ? "Refreshing" : "Refresh Hub",
                                icon: "arrow.clockwise",
                                style: .prominent
                            ) {
                                Task { await refreshHub() }
                            }
                            .disabled(refreshURL == nil || isRefreshingHub)

                            GlassButton(title: "Copy Voice URL", icon: "doc.on.doc", style: .regular) {
                                copyVoiceURL()
                            }
                            .disabled(voiceRefreshURL == nil)
                        }

                        if let refreshStatus {
                            Text(refreshStatus)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("For Google Assistant, bind the phrase \"quota refresh\" to the voice routine endpoint from Google Home, Home Assistant, IFTTT, or another webhook bridge.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, DesignSystem.Spacing.xs)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    @ViewBuilder
    private func smartHubField(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField(placeholder, text: text)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )
        }
    }

    private func smartHubProviderChip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
    }

    private func openDashboard() {
        guard let dashboardURL else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(dashboardURL)
        #endif
    }

    private func copyVoiceURL() {
        guard let voiceRefreshURL else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(voiceRefreshURL.absoluteString, forType: .string)
        refreshStatus = "Voice refresh URL copied."
        #endif
    }

    private func refreshHub() async {
        guard let refreshURL else { return }
        isRefreshingHub = true
        defer { isRefreshingHub = false }

        do {
            var request = URLRequest(url: refreshURL)
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                refreshStatus = "Refresh returned HTTP \(http.statusCode)."
            } else {
                refreshStatus = "Hub refresh requested."
            }
        } catch {
            refreshStatus = "Could not reach smart hub refresh endpoint: \(error.localizedDescription)"
        }
    }
}

struct ProviderQuotaOverviewPanel: View {
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore
    let onSelectProvider: (AgentProvider) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Quota Watch")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Review remaining quota across supported providers. Select a provider row for bucket-level detail.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                        quotaRow(for: provider)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    private func quotaRow(for provider: AgentProvider) -> some View {
        let snapshot = quotaService.snapshot(for: provider)
        let theme = ProviderTheme.theme(for: provider)
        let isActive = quotaService.isRefreshing(provider)
        let summaryText = snapshot?.summaryText
            ?? snapshot?.statusMessage
            ?? (isActive ? "Refreshing quota signal…" : "No quota snapshot yet.")

        return Button {
            onSelectProvider(provider)
        } label: {
            HStack(spacing: DesignSystem.Spacing.lg) {
                ProviderQuotaIdentityOrb(provider: provider, isActive: isActive)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(provider == .factory ? "Factory / Droid" : provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(summaryText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }

                Spacer()

                QuotaDualWindowStrip(
                    hourlyBucket: snapshot?.hourlyBucket,
                    weeklyBucket: snapshot?.weeklyBucket,
                    fallbackBucket: snapshot?.primaryDisplayableBucket,
                    provider: provider,
                    isActive: isActive
                )
                .frame(width: 180)

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                    if isActive {
                        ProviderQuotaActivityBadge(provider: provider, compact: true)
                    }

                    if let snapshot {
                        QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.56))

                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.primaryColor.opacity(isActive ? 0.18 : 0.10),
                                    theme.accentColor.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(theme.primaryColor.opacity(isActive ? 0.26 : 0.12), lineWidth: 1)
            )
            .shadow(color: theme.primaryColor.opacity(isActive ? 0.16 : 0.06), radius: isActive ? 18 : 8, y: 6)
        }
        .buttonStyle(.plain)
        .animation(DesignSystem.Animation.gentle, value: isActive)
    }
}

private struct ProviderQuotaSettingsCard: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore
    let onOpenProviderPlans: (AgentProvider) -> Void
    let quotaSourceSummary: String?

    @State private var isWorking = false
    @State private var localMiniMaxToken = ""
    @State private var localZaiToken = ""
    @State private var didLoadCredentialInputs = false
    @State private var credentialSaveMessage: String?
    @State private var credentialSaveIsError = false

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var isRefreshing: Bool {
        quotaService.isRefreshing(provider)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        ProviderQuotaIdentityOrb(provider: provider, isActive: isRefreshing)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text(providerTitle)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)

                            Text(snapshot?.summaryText ?? statusLine)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                        if isRefreshing {
                            ProviderQuotaActivityBadge(provider: provider)
                        }

                        if let snapshot {
                            QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                        }
                    }
                }

                if let quotaSourceSummary, !quotaSourceSummary.isEmpty {
                    Text(quotaSourceSummary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let snapshot, snapshot.hasDisplayableQuotaSignal {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(snapshot.displayableQuotaBuckets) { bucket in
                            ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                        }
                    }
                } else {
                    QuotaStatusCallout(
                        provider: provider,
                        title: quotaStatusCalloutTitle,
                        message: quotaService.errors[provider] ?? statusLine,
                        isActive: isRefreshing,
                        isWarning: quotaStatusCalloutWarning
                    )
                }

                if let snapshot {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Text(snapshotMetadata(snapshot))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(
                                snapshot.isStale()
                                    ? DesignSystem.Colors.warning
                                    : DesignSystem.Colors.textMuted
                            )
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        if let url = providerQuotaManagementURL(for: provider, snapshot: snapshot) {
                            Button("Open official quota") {
                                open(url: url)
                            }
                            .buttonStyle(.link)
                        }
                    }
                } else if provider == .claudeCode {
                    Text(quotaService.claudeBridgeStatus.detailText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controls
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task(id: provider) {
            loadCredentialInputsIfNeeded()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch provider {
        case .claudeCode:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    GlassButton(
                        title: quotaService.claudeBridgeStatus.isInstalled ? "Repair Bridge" : "Enable Bridge",
                        icon: quotaService.claudeBridgeStatus.isInstalled ? "wrench.and.screwdriver" : "bolt.horizontal.circle",
                        style: .prominent
                    ) {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            try? quotaService.installClaudeQuotaBridge()
                            await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
                        }
                    }

                    if quotaService.claudeBridgeStatus.isInstalled {
                        GlassButton(title: "Remove", icon: "trash", style: .regular) {
                            Task {
                                isWorking = true
                                defer { isWorking = false }
                                try? quotaService.removeClaudeQuotaBridge()
                                await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
                            }
                        }
                    }
                }
                .disabled(isWorking)
            }

        case .minimax:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Button("Manage Plans") {
                    onOpenProviderPlans(provider)
                }
                .buttonStyle(.link)

                Text("Token / API key")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                SecureField("sk-cp-…", text: $localMiniMaxToken)
                    .font(DesignSystem.Typography.monoSmall)
                    .textFieldStyle(.plain)
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    )

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button("Save token") {
                        Task { await saveCredentialToken(for: .minimax) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)

                    if !localMiniMaxToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            localMiniMaxToken = ""
                            Task { await saveCredentialToken(for: .minimax) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    }
                }

                Text("Billing mode")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Picker("MiniMax billing mode", selection: $settingsManager.miniMaxQuotaMode) {
                    ForEach(MiniMaxQuotaMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settingsManager.miniMaxQuotaMode) { _, _ in
                    Task {
                        await quotaService.refresh(provider: .minimax, dataStore: dataStore)
                    }
                }

                if let credentialSaveMessage, !credentialSaveMessage.isEmpty {
                    Text(credentialSaveMessage)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(credentialSaveIsError ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .zai:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Button("Manage Plans") {
                    onOpenProviderPlans(provider)
                }
                .buttonStyle(.link)

                Text("Token / API key")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                SecureField("zai token…", text: $localZaiToken)
                    .font(DesignSystem.Typography.monoSmall)
                    .textFieldStyle(.plain)
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    )

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button("Save token") {
                        Task { await saveCredentialToken(for: .zai) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)

                    if !localZaiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            localZaiToken = ""
                            Task { await saveCredentialToken(for: .zai) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    }
                }

                if let credentialSaveMessage, !credentialSaveMessage.isEmpty {
                    Text(credentialSaveMessage)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(credentialSaveIsError ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .factory:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Plan tier")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Picker("Factory plan tier", selection: $settingsManager.factoryQuotaPlanTier) {
                    ForEach(FactoryQuotaPlanTier.allCases) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settingsManager.factoryQuotaPlanTier) { _, _ in
                    Task {
                        await quotaService.refresh(provider: .factory, dataStore: dataStore)
                    }
                }
            }

        case .cursor:
            CursorQuotaInlineSetup(quotaService: quotaService, dataStore: dataStore)

        default:
            EmptyView()
        }
    }

    private var providerTitle: String {
        if provider == .factory {
            return "Factory / Droid"
        }
        if provider == .zai {
            return "Z.ai"
        }
        return provider.displayName
    }

    private var statusLine: String {
        if provider == .claudeCode {
            return quotaService.claudeBridgeStatus.detailText
        }
        return snapshot?.statusMessage ?? "No quota snapshot yet."
    }

    private var quotaStatusCalloutTitle: String {
        if isRefreshing {
            return "Refreshing provider signal"
        }
        if quotaService.errors[provider] != nil {
            return "Refresh needs attention"
        }
        if provider == .claudeCode {
            switch quotaService.claudeBridgeStatus.state {
            case .awaitingFirstPayload:
                return "Waiting for first Claude response"
            case .disabledByHooks:
                return "Claude hooks are disabled"
            case .invalidConfiguration:
                return "Claude bridge needs reconfiguration"
            case .ready:
                return "Claude bridge connected"
            case .notInstalled:
                return "Readable quota not available yet"
            }
        }
        return "Readable quota not available yet"
    }

    private var quotaStatusCalloutWarning: Bool {
        if quotaService.errors[provider] != nil {
            return true
        }
        guard provider == .claudeCode else {
            return false
        }
        switch quotaService.claudeBridgeStatus.state {
        case .disabledByHooks, .invalidConfiguration:
            return true
        case .notInstalled, .awaitingFirstPayload, .ready:
            return false
        }
    }

    private func snapshotMetadata(_ snapshot: ProviderQuotaSnapshot) -> String {
        let freshnessPrefix = snapshot.isStale() ? "Stale" : "Updated"
        return "\(freshnessPrefix) \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.statusMessage)"
    }

    private func open(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func loadCredentialInputsIfNeeded() {
        guard !didLoadCredentialInputs else { return }
        didLoadCredentialInputs = true

        let keyStore = ProviderAPIKeyStore.shared
        switch provider {
        case .minimax:
            localMiniMaxToken = keyStore.apiKey(for: "minimax") ?? ""
        case .zai:
            localZaiToken = keyStore.apiKey(for: "zai") ?? ""
        default:
            break
        }
    }

    private func saveCredentialToken(for provider: AgentProvider) async {
        guard provider == .minimax || provider == .zai else { return }

        isWorking = true
        defer { isWorking = false }

        let keyStore = ProviderAPIKeyStore.shared
        let rawToken = provider == .minimax ? localMiniMaxToken : localZaiToken
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if trimmed.isEmpty {
                try keyStore.removeAPIKey(for: provider == .minimax ? "minimax" : "zai")
                credentialSaveMessage = "\(provider.displayName) token cleared."
            } else {
                try keyStore.setAPIKey(trimmed, for: provider == .minimax ? "minimax" : "zai")
                credentialSaveMessage = "\(provider.displayName) token saved."
            }
            credentialSaveIsError = false
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        } catch {
            credentialSaveIsError = true
            credentialSaveMessage = "Could not save \(provider.displayName) token: \(error.localizedDescription)"
        }
    }
}

// MARK: - Cursor Inline Setup

private struct CursorQuotaInlineSetup: View {
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    private var cursorManager: CursorConnectorManager { .shared }
    private var isConnected: Bool { cursorManager.config.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Circle()
                    .fill(isConnected ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                    .frame(width: 8, height: 8)

                Text(isConnected ? "Connector active" : "Connector offline")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                if isConnected {
                    GlassButton(title: "Disconnect", icon: "stop.circle", style: .regular) {
                        Task { await cursorManager.disconnect() }
                    }
                } else {
                    GlassButton(title: "Connect", icon: "bolt.horizontal.circle", style: .prominent) {
                        Task {
                            await cursorManager.connect()
                            await quotaService.refresh(provider: .cursor, dataStore: dataStore)
                        }
                    }
                }

                GlassButton(title: "Refresh", icon: "arrow.clockwise", style: .regular) {
                    Task { await quotaService.refresh(provider: .cursor, dataStore: dataStore) }
                }
            }
            .disabled(cursorManager.isBusy)

            HStack(spacing: DesignSystem.Spacing.md) {
                GlassButton(title: "Sync Factory", icon: "arrow.triangle.2.circlepath", style: .regular) {
                    cursorManager.syncRoutedClient(.factory)
                }

                GlassButton(title: "Sync OpenCode", icon: "terminal", style: .regular) {
                    cursorManager.syncRoutedClient(.opencode)
                }
            }

            ForEach(RoutedClientTarget.allCases) { target in
                if let status = cursorManager.routedClientSyncStatuses[target] {
                    Text("\(target.displayName): \(status.summary)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = cursorManager.lastError {
                Text(error)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Text("Routed clients use OpenBurnBar's local gateway so Cursor, Factory, and OpenCode share the same plan rotation and exhausted-plan failover.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
