import AppKit
import AuthenticationServices
import SwiftUI

// MARK: - Settings Tab

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, providers, alerts, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .account: return "Account"
        case .providers: return "Providers"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .account: return "person.crop.circle.fill"
        case .providers: return "externaldrive.connected.to.line.below"
        case .alerts: return "bell.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .general: return DesignSystem.Colors.amber
        case .account: return DesignSystem.Colors.whimsy
        case .providers: return DesignSystem.Colors.ember
        case .alerts: return DesignSystem.Colors.blaze
        case .notifications: return DesignSystem.Colors.whimsy
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab? = .general

    init(
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        dataStore: DataStore
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.dataStore = dataStore
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.accentColor)
                            .frame(width: 26, height: 26)
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailContent
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(
            minWidth: 780,
            idealWidth: 920,
            minHeight: 560,
            idealHeight: 660
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab ?? .general {
        case .general:
            GeneralSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn
            )
                .navigationTitle("General")
        case .account:
            AccountSettingsView(
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                settingsManager: settingsManager
            )
            .navigationTitle("Account")
        case .providers:
            ProvidersSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Providers")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Notifications")
        }
    }
}

// MARK: - Section Header Helper

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.top, DesignSystem.Spacing.xs)
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    var sharedFeaturesAvailable: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Appearance")

                GlassCard {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Show in Menu Bar",
                            subtitle: "Display BurnBar in the system menu bar",
                            isOn: $settingsManager.showInMenuBar
                        )
                        Divider().background(DesignSystem.Colors.border)
                        SettingsToggle(
                            title: "Launch at Login",
                            subtitle: "Start BurnBar when you log in",
                            isOn: $settingsManager.launchAtLogin
                        )
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Dashboard Layout")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("Pick the surface the main window opens to. Reopen the dashboard to apply.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker("", selection: $settingsManager.dashboardLayout) {
                                ForEach(DashboardLayout.allCases) { layout in
                                    Label(layout.displayName, systemImage: layout.symbol).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }

                        Label(settingsManager.dashboardLayout.detail, systemImage: settingsManager.dashboardLayout.symbol)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .labelStyle(.titleAndIcon)
                            .animation(DesignSystem.Animation.gentle, value: settingsManager.dashboardLayout)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("Data Refresh")

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Refresh Interval")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("How often to scan for new sessions")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.refreshInterval) {
                            Text("30s").tag(TimeInterval(30))
                            Text("1m").tag(TimeInterval(60))
                            Text("5m").tag(TimeInterval(300))
                            Text("15m").tag(TimeInterval(900))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("Privacy & Search")

                PrivacyIndexingSettingsView(
                    settingsManager: settingsManager,
                    dataStore: dataStore,
                    sharedFeaturesAvailable: sharedFeaturesAvailable
                )

                sectionHeader("Session Summaries")

                SessionSummaryWizardView(settingsManager: settingsManager, dataStore: dataStore)

                sectionHeader("Default View")

                GlassCard {
                    HStack {
                        Text("Time Range")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Picker("", selection: $settingsManager.defaultTimeRange) {
                            ForEach(TimeRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Usage Display")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Dashboard and menu bar show estimated USD or token volume (M/B).")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.usageDisplayMode) {
                            Text("USD").tag(UsageDisplayMode.currency)
                            Text("Tokens").tag(UsageDisplayMode.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Privacy & Indexing

private struct PrivacyIndexingSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    var sharedFeaturesAvailable: Bool
    @State private var storageBytes: Int64 = 0
    @State private var deleteConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    @State private var embeddingModels: [EmbeddingModelRecord] = []
    @State private var embeddingVersions: [EmbeddingVersionRecord] = []
    @State private var openAIKey: String = ""
    @State private var openAIKeySaved = false
    @State private var reembedStatusMessage: String?
    @State private var reembedErrorMessage: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                SettingsToggle(
                    title: "Index Conversation Text",
                    subtitle: "Store transcripts locally for search and chat context. Never uploaded to the cloud.",
                    isOn: $settingsManager.conversationIndexingEnabled
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Allow Claude Code / Codex CLI",
                    subtitle: "Lets the in-app assistant run your local `claude` or `codex` binary. You can revoke this anytime.",
                    isOn: $settingsManager.cliAssistantAllowed
                )

                if !retrievalHealthSnapshot.degradedModes.isEmpty {
                    Divider().background(DesignSystem.Colors.border)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(retrievalHealthSnapshot.degradedModes) { state in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.warning)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.title)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(state.message)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(DesignSystem.Colors.warning.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                }

                HStack {
                    Text("Approx. indexed text")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                    Text(formatBytes(storageBytes))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)

                Divider().background(DesignSystem.Colors.border)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack {
                        Text("Index provider")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Picker("", selection: $settingsManager.indexEmbeddingProvider) {
                            Text("BurnBar Local").tag(IndexEmbeddingProviderID.deterministic)
                            Text("OpenAI").tag(IndexEmbeddingProviderID.openai)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }

                    if settingsManager.indexEmbeddingProvider == .openai {
                        HStack {
                            Text("OpenAI model")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                            Picker("", selection: $settingsManager.indexOpenAIModel) {
                                ForEach(OpenAIEmbeddingProvider.supportedModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260)
                        }

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            SecureField("OpenAI API key", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)

                            Button(openAIKeySaved ? "Saved" : "Save") {
                                saveOpenAIKey()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.blaze)
                        }

                        Text(openAIKeySaved ? "OpenAI key saved to Keychain." : "OpenAI powers semantic indexing and query embeddings for the selected index version.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(openAIKeySaved ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                    } else {
                        Text("BurnBar Local uses the built-in deterministic embedder. It is fully local and requires no network or API key.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    HStack {
                        Text("Index version")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Picker("", selection: $settingsManager.preferredIndexEmbeddingVersionID) {
                            Text("Automatic").tag("")
                            ForEach(embeddingVersions) { version in
                                Text(embeddingVersionMenuLabel(version)).tag(version.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                    }

                    HStack(spacing: DesignSystem.Spacing.xxl) {
                        metricPill(title: "Projected", value: "\(projectedDocumentCount)/\(max(indexableSourceCount, projectedDocumentCount))")
                        metricPill(title: "Embedded", value: "\(embeddedChunkCount)/\(max(indexedChunkCount, embeddedChunkCount))")
                        metricPill(title: "Queue", value: "\(retrievalHealthSnapshot.projectionQueue.queueDepth)")
                        metricPill(title: "Failed", value: "\(retrievalHealthSnapshot.projectionQueue.failedJobs)")
                    }

                    indexingProgressRow(
                        title: "Projection coverage",
                        fraction: sourceCoverageFraction,
                        detail: indexingDetailText
                    )

                    indexingProgressRow(
                        title: "Embedding coverage",
                        fraction: embeddingCoverageFraction,
                        detail: embeddingDetailText
                    )

                    if let activeVersionSummary {
                        Text("Current index: \(activeVersionSummary)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("Current index: waiting for the first indexed embedding version.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button("Re-embed all with selected provider") {
                            queueReembed()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.ember)
                        .disabled(reembedActionDisabled)

                        if let reembedStatusMessage {
                            Text(reembedStatusMessage)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    if let reembedErrorMessage {
                        Text(reembedErrorMessage)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.error)
                    }

                    Divider().background(DesignSystem.Colors.border)

                    // Cross-encoder reranking settings
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack {
                            Text("Cross-Encoder Reranking")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                        }

                        SettingsToggle(
                            title: "Enable reranking",
                            subtitle: "Sends query and candidates to a language model for improved precision. Query text is sent to your API provider.",
                            isOn: $settingsManager.crossEncoderRerankEnabled
                        )

                        if settingsManager.crossEncoderRerankEnabled {
                            HStack {
                                Text("Model")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Picker("", selection: $settingsManager.crossEncoderModel) {
                                    Text("GPT-4o Mini").tag("gpt-4o-mini")
                                    Text("GPT-4o").tag("gpt-4o")
                                    Text("GPT-4o Flash").tag("gpt-4o-flash")
                                    Text("O3 Mini").tag("o3-mini")
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 200)
                            }

                            HStack {
                                Text("Max candidates")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Stepper(
                                    "\(settingsManager.crossEncoderMaxCandidates)",
                                    value: $settingsManager.crossEncoderMaxCandidates,
                                    in: 5...64,
                                    step: 5
                                )
                                .frame(maxWidth: 180)
                            }

                            HStack {
                                Text("Chars per candidate")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Stepper(
                                    "\(settingsManager.crossEncoderMaxCharsPerCandidate)",
                                    value: $settingsManager.crossEncoderMaxCharsPerCandidate,
                                    in: 128...1024,
                                    step: 64
                                )
                                .frame(maxWidth: 200)
                            }

                            Text("Requires OpenAI API key in Index provider section above. Reranking is off by default for privacy and cost.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.sm)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)

                Button(role: .destructive) {
                    deleteConfirm = true
                } label: {
                    Text("Delete all indexed conversations")
                        .font(DesignSystem.Typography.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.md)
                }
            }
        }
        .onAppear {
            refreshStorage()
            refreshHealth()
            refreshEmbeddingLineage()
            refreshOpenAIKey()
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            refreshStorage()
            refreshHealth()
            refreshEmbeddingLineage()
        }
        .onChange(of: settingsManager.indexEmbeddingProvider) { _, _ in
            reembedStatusMessage = nil
            reembedErrorMessage = nil
            refreshOpenAIKey()
        }
        .onChange(of: settingsManager.indexOpenAIModel) { _, _ in
            reembedStatusMessage = nil
            reembedErrorMessage = nil
        }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            refreshHealth()
            refreshEmbeddingLineage()
        }
        .onChange(of: sharedFeaturesAvailable) { _, _ in
            refreshHealth()
        }
        .confirmationDialog(
            "Delete indexed conversation text?",
            isPresented: $deleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                do {
                    try dataStore.deleteAllIndexedConversations()
                    deleteErrorMessage = nil
                    refreshStorage()
                    refreshHealth()
                    refreshEmbeddingLineage()
                } catch {
                    deleteErrorMessage = "Failed to delete indexed conversations: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Token usage totals are kept. Only locally indexed transcripts are removed.")
        }
    }

    private func refreshStorage() {
        do {
            storageBytes = try dataStore.approximateConversationStorageBytes()
        } catch {
            storageBytes = 0
        }
    }

    private func refreshHealth() {
        let service = RetrievalHealthService(dataStore: dataStore)
        retrievalHealthSnapshot = service.snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: sharedFeaturesAvailable
        )
    }

    private func refreshEmbeddingLineage() {
        embeddingModels = (try? dataStore.fetchEmbeddingModels()) ?? []
        embeddingVersions = (try? dataStore.fetchEmbeddingVersions()) ?? []
    }

    private func refreshOpenAIKey() {
        openAIKey = ProviderAPIKeyStore.shared.apiKey(for: "openai") ?? ""
        openAIKeySaved = openAIKey.isEmpty == false
    }

    private func saveOpenAIKey() {
        do {
            let trimmed = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try ProviderAPIKeyStore.shared.removeAPIKey(for: "openai")
                openAIKeySaved = false
            } else {
                try ProviderAPIKeyStore.shared.setAPIKey(trimmed, for: "openai")
                openAIKeySaved = true
            }
            reembedErrorMessage = nil
        } catch {
            reembedErrorMessage = "Failed to save OpenAI key: \(error.localizedDescription)"
        }
    }

    private func queueReembed() {
        do {
            try ProjectionPipelineService.makeConfigured(
                dataStore: dataStore,
                settingsManager: settingsManager,
                providerAPIKeyStore: .shared
            ).enqueueReembedJob(reason: "manual_index_provider_refresh", priority: 5)
            reembedStatusMessage = "Re-embed queued. Progress will show above as the queue runs."
            reembedErrorMessage = nil
            refreshHealth()
        } catch {
            reembedErrorMessage = "Failed to queue re-embed: \(error.localizedDescription)"
            reembedStatusMessage = nil
        }
    }

    private var projectedDocumentCount: Int {
        (try? dataStore.countSearchDocuments()) ?? 0
    }

    private var indexedChunkCount: Int {
        (try? dataStore.countSearchChunks()) ?? 0
    }

    private var embeddedChunkCount: Int {
        (try? dataStore.countChunkEmbeddings()) ?? 0
    }

    private var indexableSourceCount: Int {
        ((try? dataStore.countConversations()) ?? 0) + ((try? dataStore.countSourceArtifacts()) ?? 0)
    }

    private var sourceCoverageFraction: Double {
        guard indexableSourceCount > 0 else { return projectedDocumentCount > 0 ? 1 : 0 }
        return min(1, Double(projectedDocumentCount) / Double(indexableSourceCount))
    }

    private var embeddingCoverageFraction: Double {
        guard indexedChunkCount > 0 else { return embeddedChunkCount > 0 ? 1 : 0 }
        return min(1, Double(embeddedChunkCount) / Double(indexedChunkCount))
    }

    private var indexingDetailText: String {
        if retrievalHealthSnapshot.rebuild.inProgress {
            return "Indexing is actively running. New records and rebuild work can still be in flight."
        }
        return "\(projectedDocumentCount) searchable records are currently projected from conversations and artifacts."
    }

    private var embeddingDetailText: String {
        if retrievalHealthSnapshot.semanticPipeline.indexedVectorCount > 0 {
            return "\(retrievalHealthSnapshot.semanticPipeline.indexedVectorCount) vectors are available for semantic ranking."
        }
        return "Semantic ranking is waiting for chunk embeddings."
    }

    private var activeVersionSummary: String? {
        let preferredVersionID = settingsManager.preferredIndexEmbeddingVersionIDValue
        let semanticVersionID = retrievalHealthSnapshot.semanticPipeline.embeddingVersionID
        let selectedVersion = embeddingVersions.first(where: { $0.id == preferredVersionID })
            ?? embeddingVersions.first(where: { $0.id == semanticVersionID })
            ?? embeddingVersions.first(where: \.isActive)
            ?? embeddingVersions.first
        guard
            let version = selectedVersion,
            let model = embeddingModels.first(where: { $0.id == version.modelID })
        else {
            return nil
        }
        return "\(model.provider) / \(model.modelName) • \(version.versionTag)"
    }

    private func embeddingVersionMenuLabel(_ version: EmbeddingVersionRecord) -> String {
        if let model = embeddingModels.first(where: { $0.id == version.modelID }) {
            return "\(model.modelName) • \(version.versionTag)"
        }
        return version.versionTag
    }

    private var reembedActionDisabled: Bool {
        guard settingsManager.conversationIndexingEnabled else { return true }
        if settingsManager.indexEmbeddingProvider == .openai {
            return openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private func indexingProgressRow(title: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            ProgressView(value: max(0.0, min(1.0, fraction)))
                .progressViewStyle(.linear)

            Text(detail)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - Session Summary Wizard

private extension SummaryProviderID {
    var displayName: String {
        switch self {
        case .local: return "Local (Ollama)"
        case .mlx: return "Local (MLX)"
        case .openrouter: return "OpenRouter"
        case .minimax: return "MiniMax"
        case .zai: return "Z.ai"
        }
    }
}

// MARK: Ollama HTTP Service

private enum OllamaService {
    struct InstalledModel: Identifiable {
        let id = UUID()
        let name: String
        let sizeBytes: Int64
        var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
        var isSummaryCandidate: Bool {
            let l = name.lowercased()
            return l.contains("qwen") || l.contains("llama") || l.contains("phi") || l.contains("mistral") || l.contains("gemma")
        }
    }

    static func listModels(baseURL: String) async throws -> [InstalledModel] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String; let size: Int64 }
            let models: [Model]
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { InstalledModel(name: $0.name, sizeBytes: $0.size) }
    }

    struct PullProgress { let completed: Int64; let total: Int64; let status: String }

    static func pullModel(_ model: String, baseURL: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/api/pull") else {
                        continuation.finish(throwing: URLError(.badURL)); return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    var buf = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if !buf.isEmpty, let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] {
                                let status = obj["status"] as? String ?? ""
                                let completed = Int64(obj["completed"] as? Int ?? 0)
                                let total = Int64(obj["total"] as? Int ?? 0)
                                continuation.yield(PullProgress(completed: completed, total: total, status: status))
                                if status == "success" { continuation.finish(); return }
                            }
                            buf = Data()
                        } else { buf.append(byte) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct SpeedUpdate {
        let tokenCount: Int
        let elapsed: Double
        let fragment: String       // latest generated text fragment
        let finalTPS: Double?      // non-nil only on final update with Ollama's eval metrics
    }

    static func streamSpeedTest(model: String, baseURL: String) -> AsyncThrowingStream<SpeedUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/api/generate") else {
                        continuation.finish(throwing: URLError(.badURL)); return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "prompt": "Write a one-sentence summary of a software coding session.",
                        "stream": true
                    ])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    struct GenChunk: Decodable {
                        let done: Bool; let response: String?
                        let eval_count: Int?; let eval_duration: Int?
                    }
                    var buf = Data()
                    var tokenCount = 0
                    let wallStart = Date()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if !buf.isEmpty, let chunk = try? JSONDecoder().decode(GenChunk.self, from: buf) {
                                let fragment = chunk.response ?? ""
                                if !fragment.isEmpty { tokenCount += 1 }
                                let elapsed = Date().timeIntervalSince(wallStart)
                                if chunk.done {
                                    let finalTPS: Double? = {
                                        if let count = chunk.eval_count, let ns = chunk.eval_duration, ns > 0 {
                                            return Double(count) / (Double(ns) / 1_000_000_000)
                                        }
                                        return elapsed > 0.1 ? Double(tokenCount) / elapsed : nil
                                    }()
                                    continuation.yield(SpeedUpdate(tokenCount: tokenCount, elapsed: elapsed, fragment: fragment, finalTPS: finalTPS))
                                    continuation.finish()
                                    return
                                }
                                continuation.yield(SpeedUpdate(tokenCount: tokenCount, elapsed: elapsed, fragment: fragment, finalTPS: nil))
                            }
                            buf = Data()
                        } else { buf.append(byte) }
                    }
                    continuation.finish(throwing: NSError(domain: "OllamaSpeedTest", code: 0, userInfo: [NSLocalizedDescriptionKey: "No output — is Ollama running with this model?"]))
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: Wizard Step

private enum SummaryWizardStep: Int, CaseIterable {
    case enable = 0, localModel = 1, cloudProviders = 2, advanced = 3, done = 4

    var title: String {
        switch self {
        case .enable: return "Enable"
        case .localModel: return "Local AI"
        case .cloudProviders: return "Cloud"
        case .advanced: return "Advanced"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .enable: return "sparkles"
        case .localModel: return "cpu"
        case .cloudProviders: return "cloud"
        case .advanced: return "slider.horizontal.3"
        case .done: return "checkmark.seal.fill"
        }
    }
}

// MARK: Session Summary Wizard

private struct SessionSummaryWizardView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore

    @State private var currentStep: SummaryWizardStep = .enable
    @State private var goingForward = true

    // Step 1
    @State private var providerOrder: [SummaryProviderID] = []
    @State private var dailyCapText = ""

    private struct ModelPreset: Identifiable {
        let id: String
        var tag: String { id }
        let size: String
        let description: String
        let recommended: Bool
    }
    private let modelPresets: [ModelPreset] = [
        ModelPreset(id: "qwen3.5:9b",   size: "~5.8 GB", description: "Best quality summaries",        recommended: true),
        ModelPreset(id: "qwen3.5:4b",   size: "~2.6 GB", description: "Good balance of speed/quality", recommended: false),
        ModelPreset(id: "qwen3.5:2b",   size: "~1.5 GB", description: "Fast, lower quality",           recommended: false),
        ModelPreset(id: "qwen3.5:0.8b", size: "~522 MB", description: "Fastest, minimal quality",      recommended: false),
        ModelPreset(id: "llama3.2:3b",  size: "~2.0 GB", description: "Meta Llama 3.2 alternative",    recommended: false),
        ModelPreset(id: "phi3.5:3.8b",  size: "~2.2 GB", description: "Microsoft Phi-3.5 alternative", recommended: false),
    ]

    // Step 2
    @State private var installedModels: [OllamaService.InstalledModel] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var dlCompleted: Int64 = 0
    @State private var dlTotal: Int64 = 0
    @State private var isDownloading = false
    @State private var dlStatusText = ""
    @State private var dlError: String?
    @State private var speedTPS: Double?
    @State private var isSpeedTesting = false
    @State private var speedError: String?
    @State private var pendingCount: Int = 0
    @State private var liveTokenCount: Int = 0
    @State private var liveElapsed: Double = 0
    @State private var liveOutput: String = ""
    @State private var showSpeedOptions = false

    // Step 3
    @State private var openRouterKey = ""
    @State private var miniMaxKey = ""
    @State private var zaiKey = ""
    @State private var keySaved: [String: Bool] = [:]
    @State private var keySaveError: String?

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                wizardHeader
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)

                Divider().background(DesignSystem.Colors.border)

                stepContent
                    .padding(DesignSystem.Spacing.lg)
                    .frame(minHeight: 340)
                    .animation(DesignSystem.Animation.standard, value: currentStep)

                Divider().background(DesignSystem.Colors.border)

                navBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.md)
            }
        }
        .onAppear { loadState() }
        .sheet(isPresented: $showSpeedOptions) {
            SpeedOptionsSheet(
                currentModel: settingsManager.summaryLocalModel,
                tps: speedTPS ?? 0,
                pendingCount: pendingCount,
                onDiskNames: Set(installedModels.map(\.name)),
                onSelectModel: { model in
                    settingsManager.summaryLocalModel = model
                    showSpeedOptions = false
                },
                onSelectMLX: { model in
                    settingsManager.summaryMLXModel = model
                    // Move .mlx to top of priority
                    var order = providerOrder
                    order.removeAll { $0 == .mlx }
                    order.insert(.mlx, at: 0)
                    providerOrder = order
                    settingsManager.setSummaryProviderOrder(order)
                    showSpeedOptions = false
                },
                onSelectCloud: { provider in
                    var order = providerOrder
                    order.removeAll { $0 == provider }
                    order.insert(provider, at: 0)
                    providerOrder = order
                    settingsManager.setSummaryProviderOrder(order)
                    showSpeedOptions = false
                }
            )
        }
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack(spacing: 0) {
            ForEach(SummaryWizardStep.allCases, id: \.rawValue) { step in
                if step.rawValue > 0 {
                    Rectangle()
                        .fill(step.rawValue <= currentStep.rawValue
                              ? DesignSystem.Colors.amber : DesignSystem.Colors.border)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .animation(DesignSystem.Animation.standard, value: currentStep)
                }
                Button {
                    guard step.rawValue <= currentStep.rawValue + 1 else { return }
                    withAnimation(DesignSystem.Animation.standard) {
                        goingForward = step.rawValue > currentStep.rawValue
                        currentStep = step
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(stepCircleColor(step))
                                .frame(width: 34, height: 34)
                                .animation(DesignSystem.Animation.standard, value: currentStep)
                            if step.rawValue < currentStep.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: step.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(step == currentStep ? .white : DesignSystem.Colors.textMuted)
                            }
                        }
                        Text(step.title)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(step == currentStep
                                             ? DesignSystem.Colors.textPrimary
                                             : DesignSystem.Colors.textMuted)
                            .fontWeight(step == currentStep ? .semibold : .regular)
                    }
                }
                .buttonStyle(.plain)
                if step.rawValue < SummaryWizardStep.allCases.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue
                              ? DesignSystem.Colors.amber : DesignSystem.Colors.border)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .animation(DesignSystem.Animation.standard, value: currentStep)
                }
            }
        }
    }

    private func stepCircleColor(_ step: SummaryWizardStep) -> Color {
        if step.rawValue < currentStep.rawValue { return DesignSystem.Colors.amber }
        if step == currentStep { return DesignSystem.Colors.blaze }
        return DesignSystem.Colors.border
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .enable:
            step1View
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
                .id(SummaryWizardStep.enable)
        case .localModel:
            step2View
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
                .id(SummaryWizardStep.localModel)
        case .cloudProviders:
            step3View
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
                .id(SummaryWizardStep.cloudProviders)
        case .advanced:
            step4View
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
                .id(SummaryWizardStep.advanced)
        case .done:
            step5View
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
                .id(SummaryWizardStep.done)
        }
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack {
            if currentStep != .enable {
                Button("← Back") {
                    withAnimation(DesignSystem.Animation.standard) {
                        goingForward = false
                        currentStep = SummaryWizardStep(rawValue: currentStep.rawValue - 1)!
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            if currentStep != .done {
                Button(currentStep == .advanced ? "Finish →" : "Next →") {
                    withAnimation(DesignSystem.Animation.standard) {
                        goingForward = true
                        currentStep = SummaryWizardStep(rawValue: currentStep.rawValue + 1)!
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
            }
        }
    }

    // MARK: - Step 1: Enable & Provider Order

    private var step1View: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Auto-Summarize Sessions")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("After each scan, BurnBar generates a title and summary for new sessions using your provider priority.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $settingsManager.autoSessionSummariesEnabled) {
                Label("Enable auto-summarization", systemImage: "sparkles")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .toggleStyle(.switch)

            if settingsManager.autoSessionSummariesEnabled {
                providerOrderSection
                dailyCapRow
            }
        }
    }

    private var providerOrderSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Provider Priority")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            VStack(spacing: 0) {
                ForEach(Array(providerOrder.enumerated()), id: \.element) { idx, provider in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .font(.system(size: 11))

                        providerBadge(provider)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Priority \(idx + 1)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Button {
                                guard idx > 0 else { return }
                                withAnimation(DesignSystem.Animation.snappy) {
                                    providerOrder.swapAt(idx, idx - 1)
                                }
                                syncOrder()
                            } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(idx == 0 ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
                            .disabled(idx == 0)

                            Button {
                                guard idx < providerOrder.count - 1 else { return }
                                withAnimation(DesignSystem.Animation.snappy) {
                                    providerOrder.swapAt(idx, idx + 1)
                                }
                                syncOrder()
                            } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(idx == providerOrder.count - 1 ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
                            .disabled(idx == providerOrder.count - 1)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.surface)

                    if idx < providerOrder.count - 1 {
                        Divider().background(DesignSystem.Colors.border)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func providerBadge(_ provider: SummaryProviderID) -> some View {
        switch provider {
        case .local:
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: "615EFF").opacity(0.15))
                Image(systemName: "cpu.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "615EFF"))
            }
            .frame(width: 28, height: 28)
        case .mlx:
            ModelProviderLogoView(modelKey: "mlx-community/model", size: 28)
        case .openrouter:
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: "00A67E").opacity(0.15))
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: "00A67E"))
            }
            .frame(width: 28, height: 28)
        case .minimax:
            ModelProviderLogoView(modelKey: "minimax-m2.7-highspeed", size: 28)
        case .zai:
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: "6366F1").opacity(0.15))
                Text("Z").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: "6366F1"))
            }
            .frame(width: 28, height: 28)
        }
    }

    private var dailyCapRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Daily cloud cap (USD)")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Limit for cloud providers; local is always free")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            HStack(spacing: DesignSystem.Spacing.sm) {
                Toggle("Unlimited", isOn: unlimitedBinding).toggleStyle(.switch).labelsHidden()
                TextField("1.00", text: Binding(
                    get: {
                        if let cap = settingsManager.summaryDailyCapUSD {
                            return dailyCapText.isEmpty ? String(format: "%.2f", cap) : dailyCapText
                        }
                        return dailyCapText
                    },
                    set: { v in
                        dailyCapText = v
                        let f = v.filter { "0123456789.".contains($0) }
                        if let val = Double(f), val > 0 { settingsManager.summaryDailyCapUSD = val }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .disabled(settingsManager.summaryDailyCapUSD == nil)
            }
        }
    }

    private var unlimitedBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.summaryDailyCapUSD == nil },
            set: { unlimited in
                if unlimited {
                    settingsManager.summaryDailyCapUSD = nil
                    dailyCapText = ""
                } else if settingsManager.summaryDailyCapUSD == nil {
                    settingsManager.summaryDailyCapUSD = 1.0
                    dailyCapText = "1.00"
                }
            }
        )
    }

    // MARK: - Step 2: Local Model

    private var step2View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "615EFF").opacity(0.15)).frame(width: 42, height: 42)
                        Image(systemName: "cpu.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color(hex: "615EFF"))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Model (Ollama)")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Free, private, runs entirely on your Mac")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                // Scan for installed models
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Models on disk")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Button {
                            Task { await scanModels() }
                        } label: {
                            if isScanning {
                                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Scanning…") }
                            } else {
                                Label("Scan system", systemImage: "magnifyingglass")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isScanning)
                    }

                    if let err = scanError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.error)
                    } else if installedModels.isEmpty && !isScanning {
                        Text("Tap \"Scan system\" to see models already on disk.")
                            .font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textMuted)
                    } else if !installedModels.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(installedModels) { model in
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    ModelProviderLogoView(modelKey: model.name, size: 22)
                                    Text(model.name)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)
                                    if model.isSummaryCandidate {
                                        Text("recommended")
                                            .font(DesignSystem.Typography.tiny)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(DesignSystem.Colors.amber.opacity(0.15))
                                            .foregroundStyle(DesignSystem.Colors.amber)
                                            .clipShape(Capsule())
                                    }
                                    Spacer()
                                    Text(String(format: "%.1f GB", model.sizeGB))
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    Button("Use") { settingsManager.summaryLocalModel = model.name }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                .padding(.horizontal, DesignSystem.Spacing.md)
                                .padding(.vertical, DesignSystem.Spacing.sm)
                                .background(settingsManager.summaryLocalModel == model.name
                                            ? DesignSystem.Colors.amber.opacity(0.08)
                                            : DesignSystem.Colors.surface)
                                if model.id != installedModels.last?.id {
                                    Divider().background(DesignSystem.Colors.border)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    }
                }

                // Model picker + download
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Choose a model")
                        .font(DesignSystem.Typography.caption).fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    let onDiskNames = Set(installedModels.map(\.name))
                    VStack(spacing: 0) {
                        ForEach(modelPresets) { preset in
                            let isSelected = settingsManager.summaryLocalModel == preset.tag
                            let onDisk = onDiskNames.contains(preset.tag)
                            Button { settingsManager.summaryLocalModel = preset.tag } label: {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    ZStack {
                                        Circle()
                                            .stroke(isSelected ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: isSelected ? 2 : 1)
                                            .frame(width: 16, height: 16)
                                        if isSelected {
                                            Circle().fill(DesignSystem.Colors.blaze).frame(width: 8, height: 8)
                                        }
                                    }
                                    ModelProviderLogoView(modelKey: preset.tag, size: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(preset.tag)
                                                .font(DesignSystem.Typography.body)
                                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                            if preset.recommended {
                                                Text("recommended")
                                                    .font(DesignSystem.Typography.tiny)
                                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(DesignSystem.Colors.amber.opacity(0.15))
                                                    .foregroundStyle(DesignSystem.Colors.amber)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(preset.description)
                                            .font(DesignSystem.Typography.tiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(preset.size)
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                        if onDisk {
                                            HStack(spacing: 3) {
                                                Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                                                Text("on disk").font(DesignSystem.Typography.tiny)
                                            }
                                            .foregroundStyle(DesignSystem.Colors.success)
                                        }
                                    }
                                }
                                .padding(.horizontal, DesignSystem.Spacing.md)
                                .padding(.vertical, DesignSystem.Spacing.sm)
                                .background(isSelected
                                            ? DesignSystem.Colors.blaze.opacity(0.06)
                                            : DesignSystem.Colors.surface)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if preset.id != modelPresets.last?.id {
                                Divider().background(DesignSystem.Colors.border)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5))

                    // Custom tag override + download button
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        ModelProviderLogoView(modelKey: settingsManager.summaryLocalModel, size: 20)
                        TextField("or type custom tag…", text: $settingsManager.summaryLocalModel)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignSystem.Typography.monoSmall)
                        Button(isDownloading ? "Downloading…" : "Download") {
                            Task { await download(settingsManager.summaryLocalModel) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.blaze)
                        .disabled(isDownloading)
                    }

                    if isDownloading || !dlStatusText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(dlStatusText)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Spacer()
                                if dlTotal > 0 {
                                    Text(String(format: "%.2f / %.2f GB",
                                               Double(dlCompleted) / 1_073_741_824,
                                               Double(dlTotal) / 1_073_741_824))
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                            }
                            if dlTotal > 0 {
                                ProgressView(value: Double(dlCompleted), total: Double(dlTotal))
                                    .tint(DesignSystem.Colors.amber)
                            } else if isDownloading {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    if let err = dlError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.error)
                    }
                }

                // Speed test
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Speed test")
                            .font(DesignSystem.Typography.caption).fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Button {
                            Task { await speedTest() }
                        } label: {
                            Label("Test speed", systemImage: "gauge.with.needle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSpeedTesting || isDownloading)
                    }

                    if isSpeedTesting {
                        // Live streaming output while test runs
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: DesignSystem.Spacing.xs) {
                                    Text("Generating…")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    if liveElapsed > 0.3, liveTokenCount > 0 {
                                        Text("·")
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                        Text(String(format: "%.0f tok/s", Double(liveTokenCount) / liveElapsed))
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.amber)
                                            .fontWeight(.semibold)
                                    }
                                }
                                if !liveOutput.isEmpty {
                                    Text(liveOutput)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    } else if let tps = speedTPS {
                        speedResultCard(tps: tps)
                    } else if let err = speedError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.error)
                    } else {
                        Text("Run a speed test to see real tokens/sec and a time estimate for pending sessions.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // MLX section (Apple Silicon)
                Divider().background(DesignSystem.Colors.border)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    ModelProviderLogoView(modelKey: "mlx-community/model", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple MLX (Apple Silicon)")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Fastest local option — uses GPU + Neural Engine via mlx_lm")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Setup")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    VStack(spacing: 0) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .frame(width: 20)
                            Text("pip install mlx-lm  &&  mlx_lm.server --model mlx-community/Qwen3-4B-4bit")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))

                        Divider().background(DesignSystem.Colors.border)

                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text("Base URL:").font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
                            TextField("http://127.0.0.1:8080", text: $settingsManager.summaryMLXBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(DesignSystem.Typography.monoSmall)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)

                        Divider().background(DesignSystem.Colors.border)

                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text("Model:").font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
                            TextField("mlx-community/Qwen3-4B-4bit", text: $settingsManager.summaryMLXModel)
                                .textFieldStyle(.roundedBorder)
                                .font(DesignSystem.Typography.monoSmall)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5))

                    Text("MLX models run via OpenAI-compatible API. Prioritize it in Step 1 to use MLX as your primary summarizer.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func speedResultCard(tps: Double) -> some View {
        let estSeconds = pendingCount > 0 ? Double(pendingCount) * 3000.0 / 4.0 / tps : 0.0
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .center, spacing: 4) {
                    Text(String(format: tps >= 10 ? "%.0f" : "%.1f", tps))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(tps >= 10 ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                    Text("tok / sec")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .frame(minWidth: 80)

                if pendingCount > 0 && estSeconds > 0 {
                    Divider().frame(height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pendingCount) sessions unsummarized")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("~\(humanDuration(estSeconds))")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("to summarize all at this speed")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.md)

            Divider().background(DesignSystem.Colors.border)

            HStack {
                Text("Not fast enough?")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                Button("Optimize →") { showSpeedOptions = true }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
    }

    // MARK: - Step 3: Cloud Providers

    private var step3View: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Cloud Providers")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Used as fallback when local Ollama is unavailable. Add API keys for the providers you want to enable.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            cloudCard(
                id: "openrouter",
                name: "OpenRouter",
                modelBinding: $settingsManager.summaryOpenRouterPrimaryModel,
                modelPlaceholder: "qwen/qwen3.5-9b",
                keyBinding: $openRouterKey,
                keyPlaceholder: "sk-or-...",
                icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: "00A67E").opacity(0.15))
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(hex: "00A67E"))
                    }
                    .frame(width: 38, height: 38)
                }
            )

            cloudCard(
                id: "minimax",
                name: "MiniMax",
                modelBinding: $settingsManager.summaryMiniMaxModel,
                modelPlaceholder: "minimax-m2.7-highspeed",
                keyBinding: $miniMaxKey,
                keyPlaceholder: "sk-...",
                icon: { ModelProviderLogoView(modelKey: "minimax-m2.7-highspeed", size: 38) }
            )

            cloudCard(
                id: "zai",
                name: "Z.ai",
                modelBinding: $settingsManager.summaryZaiModel,
                modelPlaceholder: "glm-5-turbo",
                keyBinding: $zaiKey,
                keyPlaceholder: "sk-...",
                icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: "6366F1").opacity(0.15))
                        Text("Z").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(hex: "6366F1"))
                    }
                    .frame(width: 38, height: 38)
                }
            )

            if let err = keySaveError {
                Text(err).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.error)
            }
        }
    }

    @ViewBuilder
    private func cloudCard<Icon: View>(
        id: String,
        name: String,
        modelBinding: Binding<String>,
        modelPlaceholder: String,
        keyBinding: Binding<String>,
        keyPlaceholder: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.md) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(name)
                            .font(DesignSystem.Typography.body).fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if keySaved[id] == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DesignSystem.Colors.success)
                                .font(.system(size: 13))
                        }
                    }
                    Text(modelBinding.wrappedValue)
                        .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.md)

            Divider().background(DesignSystem.Colors.border)

            VStack(spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    SecureField(keyPlaceholder, text: keyBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        saveKey(keyBinding.wrappedValue, provider: id)
                        keySaved[id] = true
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("Model:").font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
                    TextField(modelPlaceholder, text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignSystem.Typography.monoSmall)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
    }

    // MARK: - Step 4: Advanced

    private var step4View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Advanced")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                VStack(spacing: 0) {
                    advRow("Ollama base URL", "Local Ollama endpoint") {
                        TextField("http://127.0.0.1:11434", text: $settingsManager.summaryLocalBaseURL)
                            .textFieldStyle(.roundedBorder).frame(width: 230)
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("MLX base URL", "mlx_lm.server endpoint") {
                        TextField("http://127.0.0.1:8080", text: $settingsManager.summaryMLXBaseURL)
                            .textFieldStyle(.roundedBorder).frame(width: 230)
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("MLX model", "HuggingFace model ID for mlx_lm") {
                        TextField("mlx-community/Qwen3-4B-4bit", text: $settingsManager.summaryMLXModel)
                            .textFieldStyle(.roundedBorder).frame(width: 230)
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("OpenRouter fallback", "Quality fallback model") {
                        TextField("openai/gpt-5-nano", text: $settingsManager.summaryOpenRouterFallbackModel)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("Prompt chars", "Max transcript chars sent to model") {
                        Stepper(value: $settingsManager.summaryMaxPromptChars, in: 4_000...200_000, step: 2_000) {
                            Text("\(settingsManager.summaryMaxPromptChars)").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("Max output tokens", "Upper bound for generated summary") {
                        Stepper(value: $settingsManager.summaryMaxOutputTokens, in: 120...1_200, step: 20) {
                            Text("\(settingsManager.summaryMaxOutputTokens)").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("Retries", "Attempts per provider before fallback") {
                        Stepper(value: $settingsManager.summaryRetryCount, in: 0...4) {
                            Text("\(settingsManager.summaryRetryCount)").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("Batch size", "Per-scan incremental summary batch") {
                        Stepper(value: $settingsManager.summaryBatchSize, in: 1...100) {
                            Text("\(settingsManager.summaryBatchSize)").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("First-load batch", "Startup backfill batch size") {
                        Stepper(value: $settingsManager.summaryFirstLoadBatchSize, in: 1...300) {
                            Text("\(settingsManager.summaryFirstLoadBatchSize)").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                    Divider().background(DesignSystem.Colors.border)
                    advRow("Request timeout", "Seconds per provider call") {
                        Stepper(value: $settingsManager.summaryRequestTimeoutSeconds, in: 5...90, step: 1) {
                            Text("\(Int(settingsManager.summaryRequestTimeoutSeconds))s").font(DesignSystem.Typography.monoSmall)
                        }
                    }
                }
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder
    private func advRow<C: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DesignSystem.Typography.body).foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    // MARK: - Step 5: Done

    private var step5View: some View {
        VStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
            Spacer()

            ZStack {
                Circle().fill(DesignSystem.Colors.success.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("All set!").font(DesignSystem.Typography.title).foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Summaries will be generated automatically after each scan.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                summaryRow("sparkles", "Auto-summarize", settingsManager.autoSessionSummariesEnabled ? "On" : "Off")
                Divider().background(DesignSystem.Colors.border)
                summaryRow("list.number", "Provider order",
                           providerOrder.map(\.displayName).joined(separator: " → "))
                Divider().background(DesignSystem.Colors.border)
                summaryRow("cpu.fill", "Local model", settingsManager.summaryLocalModel)
                if let tps = speedTPS {
                    Divider().background(DesignSystem.Colors.border)
                    summaryRow("gauge.with.needle", "Speed", String(format: "%.0f tok/s", tps))
                }
                if pendingCount > 0, let tps = speedTPS {
                    Divider().background(DesignSystem.Colors.border)
                    summaryRow("clock", "Estimate",
                               "~\(humanDuration(Double(pendingCount) * 3000.0 / 4.0 / tps)) for \(pendingCount) sessions")
                }
            }
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
            .frame(maxWidth: 380)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func summaryRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DesignSystem.Colors.textMuted).frame(width: 18)
            Text(label).font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.caption).fontWeight(.medium)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    // MARK: - Helpers

    private func loadState() {
        providerOrder = settingsManager.summaryProviderOrder
        if let cap = settingsManager.summaryDailyCapUSD {
            dailyCapText = String(format: "%.2f", cap)
        }
        let ks = ProviderAPIKeyStore.shared
        openRouterKey = ks.apiKey(for: "openrouter") ?? ""
        miniMaxKey = ks.apiKey(for: "minimax") ?? ""
        zaiKey = ks.apiKey(for: "zai") ?? ""
        keySaved["openrouter"] = !(ks.apiKey(for: "openrouter") ?? "").isEmpty
        keySaved["minimax"] = !(ks.apiKey(for: "minimax") ?? "").isEmpty
        keySaved["zai"] = !(ks.apiKey(for: "zai") ?? "").isEmpty
        pendingCount = (try? dataStore.fetchConversationsNeedingSummary(limit: 10_000).count) ?? 0
    }

    private func syncOrder() {
        settingsManager.summaryProviderOrderCSV = providerOrder.map(\.rawValue).joined(separator: ",")
    }

    private func saveKey(_ raw: String, provider: String) {
        let ks = ProviderAPIKeyStore.shared
        do {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { try ks.removeAPIKey(for: provider) } else { try ks.setAPIKey(t, for: provider) }
            keySaveError = nil
        } catch { keySaveError = error.localizedDescription }
    }

    private func scanModels() async {
        isScanning = true; scanError = nil
        do {
            installedModels = try await OllamaService.listModels(baseURL: settingsManager.summaryLocalBaseURL)
            let names = Set(installedModels.map(\.name))
            if !names.contains(settingsManager.summaryLocalModel),
               let best = installedModels.first(where: { $0.isSummaryCandidate }) ?? installedModels.first {
                settingsManager.summaryLocalModel = best.name
            }
        } catch { scanError = error.localizedDescription }
        isScanning = false
    }

    private func download(_ model: String) async {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        isDownloading = true; dlError = nil; dlCompleted = 0; dlTotal = 0; dlStatusText = "Connecting…"
        var lastUIFlush = Date.distantPast
        var pendingCompleted: Int64 = 0
        var pendingTotal: Int64 = 0
        var pendingStatus = ""
        do {
            for try await p in OllamaService.pullModel(m, baseURL: settingsManager.summaryLocalBaseURL) {
                pendingCompleted = p.completed; pendingTotal = p.total; pendingStatus = p.status
                let now = Date()
                // Throttle UI updates to ~10 fps to avoid layout recursion
                if now.timeIntervalSince(lastUIFlush) >= 0.1 || p.status == "success" {
                    lastUIFlush = now
                    dlCompleted = pendingCompleted; dlTotal = pendingTotal; dlStatusText = pendingStatus
                }
            }
            dlCompleted = pendingCompleted; dlTotal = pendingTotal
            dlStatusText = "Downloaded \(m)"
            await scanModels()
        } catch { dlError = error.localizedDescription; dlStatusText = "" }
        isDownloading = false
    }

    private func speedTest() async {
        isSpeedTesting = true; speedError = nil; speedTPS = nil
        liveTokenCount = 0; liveElapsed = 0; liveOutput = ""
        do {
            for try await update in OllamaService.streamSpeedTest(
                model: settingsManager.summaryLocalModel,
                baseURL: settingsManager.summaryLocalBaseURL
            ) {
                liveTokenCount = update.tokenCount
                liveElapsed = update.elapsed
                liveOutput += update.fragment
                if let final = update.finalTPS {
                    speedTPS = final
                }
            }
            if speedTPS == nil, liveElapsed > 0.1, liveTokenCount > 0 {
                speedTPS = Double(liveTokenCount) / liveElapsed
            }
        } catch { speedError = error.localizedDescription }
        isSpeedTesting = false
    }

    private func humanDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f sec", seconds) }
        if seconds < 3600 { return String(format: "%.0f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}

// MARK: - Speed Options Sheet

private struct SpeedOptionsSheet: View {
    let currentModel: String
    let tps: Double
    let pendingCount: Int
    let onDiskNames: Set<String>
    let onSelectModel: (String) -> Void
    let onSelectMLX: (String) -> Void
    let onSelectCloud: (SummaryProviderID) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct LocalOption: Identifiable {
        let id: String
        let size: String
        let description: String
    }

    private let options: [LocalOption] = [
        LocalOption(id: "qwen3.5:9b",   size: "5.8 GB", description: "Best quality summaries"),
        LocalOption(id: "qwen3.5:4b",   size: "2.6 GB", description: "Good balance of speed/quality"),
        LocalOption(id: "qwen3.5:2b",   size: "1.5 GB", description: "Fast, lower quality"),
        LocalOption(id: "qwen3.5:0.8b", size: "522 MB", description: "Fastest, minimal quality"),
        LocalOption(id: "llama3.2:3b",  size: "2.0 GB", description: "Meta Llama 3.2 alternative"),
        LocalOption(id: "phi3.5:3.8b",  size: "2.2 GB", description: "Microsoft Phi-3.5 alternative"),
    ]

    private var fasterOptions: [LocalOption] {
        guard let idx = options.firstIndex(where: { $0.id == currentModel }) else {
            return options.filter { $0.id != currentModel }
        }
        return Array(options[(idx + 1)...])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "gauge.medium.badge.plus")
                            .foregroundStyle(DesignSystem.Colors.amber)
                        Text("Optimize Speed")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    Group {
                        if pendingCount > 0 {
                            Text("Current: \(currentModel) · \(String(format: "%.0f", tps)) tok/s · \(pendingCount) sessions pending")
                        } else {
                            Text("Current: \(currentModel) · \(String(format: "%.0f", tps)) tok/s")
                        }
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(DesignSystem.Spacing.lg)

            Divider().background(DesignSystem.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                    // Faster local models
                    if !fasterOptions.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Label("Faster Local Models", systemImage: "cpu")
                                .font(DesignSystem.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Text("Smaller models run significantly faster at the cost of summary quality.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(spacing: 0) {
                                ForEach(fasterOptions) { option in
                                    localOptionRow(option)
                                    if option.id != fasterOptions.last?.id {
                                        Divider().background(DesignSystem.Colors.border)
                                    }
                                }
                            }
                            .background(DesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                        }
                    }

                    // MLX option (Apple Silicon)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Apple MLX (Fastest Local)", systemImage: "memorychip.fill")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("Uses Apple GPU + Neural Engine. Requires mlx_lm.server running on port 8080.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            mlxOptionRow("mlx-community/Qwen3-4B-4bit", "~2.4 GB · Best for summarization")
                            Divider().background(DesignSystem.Colors.border)
                            mlxOptionRow("mlx-community/Qwen3-1.7B-4bit", "~1.0 GB · Ultra-fast, good quality")
                            Divider().background(DesignSystem.Colors.border)
                            mlxOptionRow("mlx-community/Llama-3.2-3B-Instruct-4bit", "~1.8 GB · Meta Llama 3.2")
                        }
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    }

                    // Cloud providers
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Switch to Cloud", systemImage: "cloud")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("Prioritize a cloud provider. Local Ollama becomes the fallback.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            cloudOptionRow(
                                provider: .openrouter,
                                name: "OpenRouter",
                                description: "Fast inference, 200+ models, pay-per-token",
                                icon: AnyView(
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color(hex: "00A67E").opacity(0.15))
                                        Image(systemName: "arrow.triangle.branch")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color(hex: "00A67E"))
                                    }.frame(width: 34, height: 34)
                                )
                            )
                            Divider().background(DesignSystem.Colors.border)
                            cloudOptionRow(
                                provider: .minimax,
                                name: "MiniMax",
                                description: "High-speed, low-cost cloud API",
                                icon: AnyView(ModelProviderLogoView(modelKey: "minimax-m2.7-highspeed", size: 34))
                            )
                            Divider().background(DesignSystem.Colors.border)
                            cloudOptionRow(
                                provider: .zai,
                                name: "Z.ai",
                                description: "Sub-second cloud summaries",
                                icon: AnyView(ModelProviderLogoView(modelKey: "glm-4", size: 34))
                            )
                        }
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider().background(DesignSystem.Colors.border)

            HStack {
                Spacer()
                Button("Keep current model") { dismiss() }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .frame(width: 480)
        .frame(minHeight: 500)
        .background(DesignSystem.Colors.background)
    }

    @ViewBuilder
    private func localOptionRow(_ option: LocalOption) -> some View {
        let isOnDisk = onDiskNames.contains(option.id)
        HStack(spacing: DesignSystem.Spacing.md) {
            ModelProviderLogoView(modelKey: option.id, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(option.id)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if isOnDisk {
                        Text("on disk")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.success.opacity(0.15))
                            .foregroundStyle(DesignSystem.Colors.success)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(option.description)
                    Text("·")
                    Text(option.size)
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button(isOnDisk ? "Use" : "Download & Use") {
                onSelectModel(option.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isOnDisk ? DesignSystem.Colors.blaze : nil)
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func mlxOptionRow(_ modelId: String, _ subtitle: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ModelProviderLogoView(modelKey: modelId, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(modelId)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button("Use") { onSelectMLX(modelId) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func cloudOptionRow(provider: SummaryProviderID, name: String, description: String, icon: AnyView) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(description)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button("Prioritize") {
                onSelectCloud(provider)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DesignSystem.Colors.blaze)
        }
        .padding(DesignSystem.Spacing.md)
    }
}

// MARK: - Providers Settings

private struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    @State private var quotaService = ProviderQuotaService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                BurnBarDaemonCard(dataStore: dataStore)

                Text("Install the daemon for BurnBar-routed models (editor extension). Log paths below stay for usage parsing from each agent’s files.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.bottom, DesignSystem.Spacing.sm)

                sectionHeader("Quota Reporting")

                ProviderQuotaSettingsSection(
                    settingsManager: settingsManager,
                    quotaService: quotaService,
                    dataStore: dataStore
                )

                sectionHeader("Log File Paths")

                ForEach(AgentProvider.allCases) { provider in
                    ProviderSettingsRow(
                        provider: provider,
                        path: Binding(
                            get: { settingsManager.logPaths[provider] ?? provider.logDirectory },
                            set: {
                                settingsManager.logPaths[provider] = $0.isEmpty ? provider.logDirectory : $0
                            }
                        ),
                        onBrowse: {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: (provider.logDirectory as NSString).expandingTildeInPath)

                            DispatchQueue.main.async {
                                if panel.runModal() == .OK, let url = panel.url {
                                    settingsManager.logPaths[provider] = url.path
                                }
                            }
                        },
                        pathExists: settingsManager.pathExists(for: provider)
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}

private struct BurnBarDaemonCard: View {
    let dataStore: DataStore
    @State private var daemonManager = BurnBarDaemonManager.shared

    private var statusColor: Color {
        switch daemonManager.status {
        case .healthy:
            return DesignSystem.Colors.success
        case .notInstalled:
            return DesignSystem.Colors.textMuted
        case .checking:
            return DesignSystem.Colors.warning
        case .unhealthy:
            return DesignSystem.Colors.error
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("BurnBar Daemon")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("The local daemon owns BurnBar runtime state, provider routing, and recovery once the app is closed.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(daemonManager.status.label)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                Text(daemonManager.detailText)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(daemonManager.socketPathDisplay)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)

                Text(daemonManager.runtimeStateSource.detailText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !daemonManager.providerConfigurations.isEmpty {
                    Divider().background(DesignSystem.Colors.border)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Daemon-backed providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ForEach(daemonManager.providerConfigurations) { configuration in
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Text(configuration.displayName)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                                    Toggle(
                                        configuration.isEnabled ? "Enabled" : "Disabled",
                                        isOn: Binding(
                                            get: { configuration.isEnabled },
                                            set: { newValue in
                                                Task {
                                                    await daemonManager.updateProviderConfiguration(
                                                        providerID: configuration.providerID,
                                                        isEnabled: newValue
                                                    )
                                                }
                                            }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()

                                    Spacer()
                                }

                                TextField(
                                    "Base URL",
                                    text: Binding(
                                        get: { configuration.baseURL },
                                        set: { newValue in
                                            Task {
                                                await daemonManager.updateProviderConfiguration(
                                                    providerID: configuration.providerID,
                                                    baseURL: newValue
                                                )
                                            }
                                        }
                                    )
                                )
                                .font(DesignSystem.Typography.monoTiny)
                                .textFieldStyle(.plain)
                                .padding(DesignSystem.Spacing.sm)
                                .background(DesignSystem.Colors.background)
                                .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                )

                                if !configuration.preferredModelIDs.isEmpty {
                                    TextField(
                                        "Preferred models",
                                        text: Binding(
                                            get: { configuration.preferredModelIDs.joined(separator: ", ") },
                                            set: { newValue in
                                                let models = newValue
                                                    .split(separator: ",")
                                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                    .filter { !$0.isEmpty }
                                                Task {
                                                    await daemonManager.updateProviderConfiguration(
                                                        providerID: configuration.providerID,
                                                        preferredModelIDs: models
                                                    )
                                                }
                                            }
                                        )
                                    )
                                    .font(DesignSystem.Typography.caption)
                                    .textFieldStyle(.plain)
                                    .padding(DesignSystem.Spacing.sm)
                                    .background(DesignSystem.Colors.background)
                                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                    )
                                }
                            }
                        }
                    }
                }

                Divider().background(DesignSystem.Colors.border)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Recent daemon usage")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    if daemonManager.recentUsage.isEmpty {
                        Text("No daemon usage has been mirrored into BurnBar yet.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("\(daemonManager.usageLedgerCount) daemon usage record\(daemonManager.usageLedgerCount == 1 ? "" : "s") available in BurnBar's local history.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        ForEach(daemonManager.recentUsage.prefix(4)) { usage in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text("\(usage.provider.displayName) · \(usage.model)")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(usage.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                                    Text(usage.cost.formatAsCost())
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text("\(usage.totalTokens) tokens")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }

                if !daemonManager.recentEvents.isEmpty {
                    Divider().background(DesignSystem.Colors.border)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Recent daemon events")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ForEach(Array(daemonManager.recentEvents.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack(spacing: DesignSystem.Spacing.md) {
                    GlassButton(title: "Install", icon: "arrow.down.circle", style: .prominent) {
                        Task { await daemonManager.installAndStart() }
                    }

                    GlassButton(title: "Repair", icon: "wrench.and.screwdriver", style: .regular) {
                        Task { await daemonManager.repair() }
                    }

                    GlassButton(title: "Check", icon: "waveform.path.ecg", style: .regular) {
                        Task { await daemonManager.refreshHealth() }
                    }

                    GlassButton(title: "Uninstall", icon: "trash", style: .regular) {
                        Task { await daemonManager.uninstall() }
                    }
                }
                .disabled(daemonManager.isBusy)

                if let error = daemonManager.lastError, !error.isEmpty {
                    Text(error)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                Text("Provider settings now save through the daemon when it is healthy. If the daemon is unavailable, BurnBar falls back to the local mirror in read-only mode.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            daemonManager.attach(dataStore: dataStore)
            await daemonManager.refreshHealth()
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: AgentProvider
    @Binding var path: String
    let onBrowse: () -> Void
    let pathExists: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var statusColor: Color {
        switch provider.supportLevel {
        case .supported: return DesignSystem.Colors.success
        case .partial: return DesignSystem.Colors.warning
        case .unsupported: return DesignSystem.Colors.textMuted
        }
    }

    private var supportLevelText: String {
        switch provider.supportLevel {
        case .supported: return "Supported"
        case .partial: return "Partial support"
        case .unsupported: return "Not yet supported"
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .fill(theme.primaryColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)
                    }

                    Text(provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                        Text(supportLevelText)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    TextField("Path", text: $path)
                        .font(DesignSystem.Typography.monoSmall)
                        .textFieldStyle(.plain)
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.background)
                        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                        )

                    Image(systemName: pathExists ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(pathExists ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                        .help(pathExists ? "Path exists" : "Path not found")

                    Button("Browse...") { onBrowse() }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("Default:")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(provider.logDirectory)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                if provider.supportLevel == .unsupported {
                    Text("Log parsing for \(provider.displayName) is not yet implemented. Data will appear once support is added.")
                        .font(DesignSystem.Typography.caption)
                        .italic()
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }
}

// MARK: - Alerts Settings

private struct AlertsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @State private var alertEnabled: Bool = false
    @State private var alertThreshold: Double = 10.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Daily Cost Alert")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        Toggle(isOn: $alertEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Enable Alert")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("Get notified when daily spending exceeds threshold")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: alertEnabled) { _, newValue in
                            settingsManager.costAlertThreshold = newValue ? alertThreshold : nil
                        }

                        if alertEnabled {
                            HStack {
                                Text("Alert when daily cost exceeds")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                TextField("", value: $alertThreshold, format: .number)
                                    .textFieldStyle(.plain)
                                    .font(DesignSystem.Typography.mono)
                                    .padding(DesignSystem.Spacing.sm)
                                    .background(DesignSystem.Colors.background)
                                    .frame(width: 80)
                                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                    )
                                    .onChange(of: alertThreshold) { _, newValue in
                                        settingsManager.costAlertThreshold = newValue
                                    }
                                Text("USD")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("About")

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BurnBar")
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Version 1.0.0")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .onAppear {
            alertEnabled = settingsManager.costAlertThreshold != nil
            alertThreshold = settingsManager.costAlertThreshold ?? 10.0
        }
    }
}

// MARK: - Notifications Settings

private struct NotificationsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Daily Digest")

                GlassCard {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Daily Digest",
                            subtitle: "Brief summary of today's agent spend at the chosen hour",
                            isOn: $settingsManager.dailyDigestEnabled
                        )

                        Divider().background(DesignSystem.Colors.border)

                        HStack {
                            Text("Send at")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                            Picker("Hour", selection: $settingsManager.dailyDigestHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        .padding(DesignSystem.Spacing.lg)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .onChange(of: settingsManager.dailyDigestEnabled) { _, on in
            Task {
                if on {
                    await DailyDigestManager.shared.requestAuthorization()
                    DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
                } else {
                    DailyDigestManager.shared.cancelDigest()
                }
            }
        }
        .onChange(of: settingsManager.dailyDigestHour) { _, h in
            if settingsManager.dailyDigestEnabled {
                DailyDigestManager.shared.scheduleDigest(from: dataStore, at: h)
            }
        }
        .onAppear {
            if settingsManager.dailyDigestEnabled {
                DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
            }
        }
    }
}

// MARK: - Settings Toggle

private struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .padding(DesignSystem.Spacing.lg)
    }
}

// MARK: - Account Settings

private struct AccountSettingsView: View {
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    @Bindable var settingsManager: SettingsManager

    @State private var isSigningInGoogle = false
    @State private var isSigningInApple = false
    @State private var signInError: String?
    @State private var showICloudSessionSetup = false

    /// Prefers Firebase/Auth `userInfo` keys over the generic `localizedDescription` (e.g. keychain errors).
    private static func signInErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            return reason
        }
        if let suggestion = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String, !suggestion.isEmpty {
            return suggestion
        }
        return error.localizedDescription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if accountManager.isFirebaseAvailable {
                    firebaseCloudSyncContent
                } else {
                    notConfiguredBanner
                }
                iCloudSessionMirrorSection
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showICloudSessionSetup) {
            if let mirror = iCloudSessionMirrorService {
                ICloudSessionSetupSheet(mirrorService: mirror, settingsManager: settingsManager)
            } else {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Text("Open Settings from the running BurnBar app to use the iCloud setup guide.")
                        .font(DesignSystem.Typography.body)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(minWidth: 320, minHeight: 120)
            }
        }
    }

    // MARK: - Not Configured

    private var notConfiguredBanner: some View {
        accountPanel {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.warning)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Firebase not configured")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Add GoogleService-Info.plist to enable account sync. See the README for setup instructions.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Firebase account & Firestore sync

    @ViewBuilder
    private var firebaseCloudSyncContent: some View {
        sectionHeader("Account")

        if accountManager.isSignedIn {
            accountPanel {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DesignSystem.Colors.whimsy.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountManager.userDisplayName ?? "Signed in")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if let email = accountManager.userEmail {
                            Text(email)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    Button("Sign Out") {
                        try? accountManager.signOut()
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.error.opacity(0.12))
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .buttonStyle(.plain)
                }
            }

            sectionHeader("Firestore sync")

            accountPanel {
                VStack(spacing: 0) {
                    SettingsToggle(
                        title: "Enable Cloud Sync",
                        subtitle: "Upload token usage to Firestore for cross-device totals",
                        isOn: Binding(
                            get: { accountManager.isCloudSyncEnabled },
                            set: { accountManager.setCloudSyncEnabled($0) }
                        )
                    )

                    Divider().background(DesignSystem.Colors.border)

                    SettingsToggle(
                        title: "Back Up Session History",
                        subtitle: "Sync session metadata (not full transcripts) to Firestore for recall on your signed-in Macs",
                        isOn: $settingsManager.conversationCloudBackupEnabled
                    )
                    .disabled(!accountManager.isSignedIn || !accountManager.isCloudSyncEnabled)

                    Divider().background(DesignSystem.Colors.border)

                    syncStatusRow
                }
            }
        } else {
            accountPanel {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Firestore sync")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Sign in with Google or Apple to sync usage totals across your Macs. Data stays in your Firebase project (Firestore).")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = signInError {
                        Text(error)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: DesignSystem.Spacing.sm) {
                        GoogleSignInBrandButton(isLoading: isSigningInGoogle) {
                            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
                            Task { @MainActor in
                                isSigningInGoogle = true
                                signInError = nil
                                defer { isSigningInGoogle = false }
                                do {
                                    try await accountManager.signInWithGoogle(presentingWindow: window)
                                } catch {
                                    signInError = Self.signInErrorMessage(error)
                                }
                            }
                        }

                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = accountManager.appleSignInNonceHash()
                        } onCompletion: { result in
                            Task { @MainActor in
                                switch result {
                                case .success(let authorization):
                                    isSigningInApple = true
                                    signInError = nil
                                    defer { isSigningInApple = false }
                                    do {
                                        try await accountManager.signInWithAppleAuthorization(authorization)
                                    } catch {
                                        if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                            signInError = Self.signInErrorMessage(error)
                                        }
                                    }
                                case .failure(let error):
                                    if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                        signInError = Self.signInErrorMessage(error)
                                    }
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if isSigningInApple {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.black.opacity(0.08))
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isSigningInApple)
                    }
                }
            }
        }
    }

    // MARK: - iCloud session file mirror

    private var iCloudSessionMirrorSection: some View {
        Group {
            sectionHeader("iCloud session files")

            accountPanel {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text(
                        "Keep a copy of on-disk session logs in your personal iCloud Drive. This is separate from Firebase and does not require signing in to BurnBar."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    SettingsToggle(
                        title: "Mirror session files to iCloud",
                        subtitle: "Copies supported provider logs into BurnBar’s iCloud folder after each refresh",
                        isOn: $settingsManager.iCloudSessionMirrorEnabled
                    )

                    Button {
                        showICloudSessionSetup = true
                    } label: {
                        Label("Set up guide…", systemImage: "hand.raised.fill")
                            .font(DesignSystem.Typography.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                    .disabled(iCloudSessionMirrorService == nil)

                    Divider().background(DesignSystem.Colors.border)

                    iCloudMirrorStatusRow
                }
            }
        }
    }

    private var iCloudMirrorStatusRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last iCloud mirror")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Group {
                    if let error = iCloudSessionMirrorService?.lastSyncError {
                        Text(error)
                            .foregroundStyle(DesignSystem.Colors.error)
                    } else if let date = iCloudSessionMirrorService?.lastSyncDate {
                        Text(date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("Not yet")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .font(DesignSystem.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)

                if let m = iCloudSessionMirrorService, m.lastSyncUpdatedCount > 0 || m.lastSyncRemovedCount > 0,
                   m.lastSyncError == nil, m.lastSyncDate != nil {
                    Text(
                        "Updated \(m.lastSyncUpdatedCount) file(s), removed \(m.lastSyncRemovedCount) from mirror"
                    )
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            Spacer()

            if iCloudSessionMirrorService?.isSyncing == true {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Mirroring")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                Image(
                    systemName: iCloudSessionMirrorService?.lastSyncError != nil
                        ? "exclamationmark.icloud.fill"
                        : "icloud.fill"
                )
                .font(.system(size: 14))
                .foregroundStyle(
                    iCloudSessionMirrorService?.lastSyncError != nil
                        ? DesignSystem.Colors.error
                        : DesignSystem.Colors.textSecondary
                )
            }
        }
    }

    private func accountPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }

    // MARK: - Sync Status Row

    /// Firestore returns this when rules only allow `usage` but the app also writes `conversations` / `session_logs`.
    private var firestorePermissionHint: String? {
        guard let err = cloudSyncService?.lastSyncError else { return nil }
        let e = err.lowercased()
        guard e.contains("permission") || e.contains("insufficient") else { return nil }
        return "Your Firebase security rules must allow read/write under your user path for usage, conversations, and session_logs (including chunks). This is not the iCloud mirror below. See README → Cloud sync, or use firestore.rules in the repo."
    }

    private var collaborationNoticeHint: (text: String, color: Color)? {
        guard let notice = cloudSyncService?.lastCollaborationNotice else { return nil }
        let relativeTime = notice.occurredAt.formatted(.relative(presentation: .named))
        let text = "\(notice.kind.title): \(notice.message) (\(relativeTime))"
        switch notice.kind {
        case .remoteUpdateArrived:
            return (text, DesignSystem.Colors.textSecondary)
        case .editConflicted:
            return (text, DesignSystem.Colors.error)
        case .resolvedVersionSaved:
            return (text, DesignSystem.Colors.success)
        }
    }

    private var syncStatusRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last Firestore sync")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Group {
                    if let error = cloudSyncService?.lastSyncError {
                        Text("Error: \(error)")
                            .foregroundStyle(DesignSystem.Colors.error)
                    } else if let date = cloudSyncService?.lastSyncDate {
                        Text(date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .font(DesignSystem.Typography.caption)

                if let hint = firestorePermissionHint {
                    Text(hint)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let notice = collaborationNoticeHint {
                    Text(notice.text)
                        .font(.caption2)
                        .foregroundStyle(notice.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if cloudSyncService?.isSyncing == true {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Syncing")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                Image(systemName: cloudSyncService?.lastSyncError != nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        cloudSyncService?.lastSyncError != nil
                            ? DesignSystem.Colors.error
                            : DesignSystem.Colors.success
                    )
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }
}

// MARK: - iCloud session setup (white glove)

private struct ICloudSessionSetupSheet: View {
    var mirrorService: ICloudSessionMirrorService
    @Bindable var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAdvanced = false
    @State private var isRunningMirror = false
    @State private var estimatedBytes: Int64 = 0
    @State private var isEstimatingSize = true

    private var estimatedString: String {
        if isEstimatingSize {
            return "Calculating…"
        }
        return ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }

    private var mirrorProviders: [AgentProvider] {
        AgentProvider.allCases.filter { $0.supportLevel != .unsupported }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if mirrorService.hasUbiquityIdentity {
                        statusOkBanner
                    } else {
                        iCloudSignInBanner
                    }

                    privacyCard

                    providersCard

                    actionsCard

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        advancedSymlinkCard
                    } label: {
                        Text("Advanced: point agents at an iCloud folder")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    .padding(DesignSystem.Spacing.lg)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                                .fill(DesignSystem.Colors.surface.opacity(0.55))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .background(DesignSystem.Colors.background)
            .navigationTitle("iCloud session backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .task {
            isEstimatingSize = true
            estimatedBytes = await mirrorService.estimatedTotalBytesToMirror()
            isEstimatingSize = false
        }
    }

    private var statusOkBanner: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignSystem.Colors.success)
            VStack(alignment: .leading, spacing: 4) {
                Text("iCloud is available on this Mac")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("BurnBar can write to your app folder in iCloud Drive. If the folder is empty at first, run a refresh or use “Mirror now” below.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.success.opacity(0.12))
        }
    }

    private var iCloudSignInBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to iCloud")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Open System Settings, sign in with your Apple ID, and turn on iCloud Drive. Then return here and try again.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Open Apple ID settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.warning.opacity(0.12))
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Privacy")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(
                "Session files can include project paths, prompts, and snippets of code. They are copied to your Apple ID’s iCloud storage—not to BurnBar’s servers. Large trees can use significant iCloud quota."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "If two Macs change the same mirrored file, iCloud may create conflict copies. Keep agents quit on one Mac while moving folders."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
    }

    private var providersCard: some View {
        let logPaths = settingsManager.logPaths
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("What we mirror")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Rough total right now: \(estimatedString) (estimate only).")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ForEach(mirrorProviders, id: \.self) { provider in
                let path = logPaths[provider] ?? provider.logDirectory
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Finish setup")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Toggle("Enable mirror after each refresh", isOn: $settingsManager.iCloudSessionMirrorEnabled)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    Task {
                        isRunningMirror = true
                        defer { isRunningMirror = false }
                        settingsManager.iCloudSessionMirrorEnabled = true
                        await mirrorService.syncIfNeeded()
                    }
                } label: {
                    if isRunningMirror {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Mirror now")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningMirror || !mirrorService.hasUbiquityIdentity)

                Button("Reveal in Finder") {
                    if let url = mirrorService.mirrorRootDirectoryURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                .disabled(mirrorService.mirrorRootDirectoryURL() == nil)
            }

            Text("Finder path: iCloud Drive → BurnBar → SessionMirror (inside the app’s iCloud Documents).")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
    }

    private var advancedSymlinkCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(
                "BurnBar does not move your agent folders automatically. To make Factory (or another tool) write directly into iCloud, quit that tool, back up the folder, then run commands in Terminal."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            symlinkBlock(
                title: "Example: Factory sessions",
                command: """
                # Quit Factory first. DEST = a folder you create inside the BurnBar iCloud area (use Reveal in Finder).
                mv ~/.factory/sessions \"$DEST/factory-sessions\"
                ln -s \"$DEST/factory-sessions\" ~/.factory/sessions
                """
            )

            symlinkBlock(
                title: "Example: Kimi sessions",
                command: """
                # Quit Kimi agents first.
                mv ~/.kimi/sessions \"$DEST/kimi-sessions\"
                ln -s \"$DEST/kimi-sessions\" ~/.kimi/sessions
                """
            )
        }
        .padding(.top, DesignSystem.Spacing.sm)
    }

    private func symlinkBlock(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .textSelection(.enabled)
            Button("Copy commands") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.whimsy)
        }
        .padding(.vertical, 4)
    }
}

/// Google's branded "Sign in with Google" treatment (light background + stroke).
/// GoogleSignInSwift's `GoogleSignInButton` is excluded on arm64 in the SDK, so we match the guidelines manually.
private struct GoogleSignInBrandButton: View {
    var isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("G")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: "4285F4"))
                }
                Text(isLoading ? "Signing in…" : "Sign in with Google")
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(Color(hex: "3C4043"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(hex: "747775").opacity(0.38), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

#Preview {
    SettingsView(settingsManager: SettingsManager.shared, dataStore: DataStore())
}
