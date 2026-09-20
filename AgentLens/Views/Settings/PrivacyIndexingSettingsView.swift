import SwiftUI
import OpenBurnBarCore

// MARK: - Privacy & Indexing Settings View

/// Settings view for privacy, indexing, and embedding configuration
struct PrivacyIndexingSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    var sharedFeaturesAvailable: Bool
    /// Wired when a memory backend is available (nil today, until backend PR-5).
    /// When nil, "Reset memory" is disabled — extraction is already a no-op.
    var memoryService: (any MemoryServing)?
    /// Live runtime context, threaded so the "Review pending memories" link can
    /// build the inbox over the shared `ControlPlaneStore`. Optional so settings
    /// surfaces that have no runtime context still compile (the link then shows a
    /// graceful unavailable state).
    var runtimeContext: OpenBurnBarRuntimeContext?
    var accountManager: AccountManager = .shared
    @State private var storageBytes: Int64 = 0
    @State private var conversationCount: Int = 0
    @State private var sourceArtifactCount: Int = 0
    @State private var deleteConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var memoryResetConfirm = false
    @State private var memoryResetStatus: String?
    @State private var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    @State private var embeddingModels: [EmbeddingModelRecord] = []
    @State private var embeddingVersions: [EmbeddingVersionRecord] = []
    @State private var projectedDocumentCountValue: Int = 0
    @State private var indexedChunkCountValue: Int = 0
    @State private var embeddedChunkCountValue: Int = 0
    @State private var openAIKey: String = ""
    @State private var openAIKeySaved = false
    @State private var reembedStatusMessage: String?
    @State private var reembedErrorMessage: String?
    /// Live Data Vault entitlement (Pro Max or Ultra), the same gate the
    /// cloud-models section unlocks against. Feeds `memoryDeviceSyncEntitlementSatisfied`
    /// so the device-sync row's presentation gate never needs its own Firebase
    /// dependency.
    @ObservedObject private var deviceSyncEntitlement = MacCloudEntitlementStore.shared
    @State private var showDeviceSyncUnlockSheet = false
    /// Collapsed by default: the sync-status row answers "why has nothing
    /// arrived", which is a question a member only asks when something looks
    /// wrong. Mirrors the Advanced disclosure in Connections.
    @State private var isMemorySyncStatusExpanded = false
    @State private var showTeamMemoryUnlockSheet = false
    @State private var teamMemoryModel: TeamMemorySectionModel?
    private static let deviceSyncGatedFeature = GatedFeature.gatedFeature(.dataVault)

    /// Opt-in analytics consent toggle. Reads/writes the shared tri-state consent
    /// store and notifies the recorder so the Amplitude SDK starts on grant and
    /// stops on revoke. Off by default; revoking stops all future sends at once.
    private var analyticsConsentBinding: Binding<Bool> {
        Binding(
            get: { AnalyticsConsentStore.shared.isGranted },
            set: { isOn in
                if isOn { AnalyticsConsentStore.shared.grant() } else { AnalyticsConsentStore.shared.revoke() }
                Analytics.shared.consentDidChange()
            }
        )
    }

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
                    title: "Share Usage Analytics",
                    subtitle: "Send privacy-preserving product-usage events to Amplitude to help improve OpenBurnBar. Off by default. Never includes conversation content, API keys, secrets, or message bodies — you can turn it off anytime.",
                    isOn: analyticsConsentBinding
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Mac CLI Assistants",
                    subtitle: "Lets OpenBurnBar run approved local CLI agents like `claude`, `codex`, `droid`, `forge`, or `agy` for chat and reranking. You can revoke this anytime.",
                    isOn: $settingsManager.cliAssistantAllowed
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Back Up Chat Message Content",
                    subtitle: chatContentBackupSubtitle,
                    isOn: chatContentBackupBinding
                )

                Divider().background(DesignSystem.Colors.border)

                // MARK: - Memory (G4: user toggle + fleet kill switch)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Memory",
                        subtitle: "OpenBurnBar learns preferences from your chats and recalls them in future turns. Memories are never injected as trusted instructions — they ride in the untrusted evidence region.",
                        isOn: $settingsManager.memoryAutomaticExtraction
                    )

                    if settingsManager.memoryAutomaticExtraction {
                        SettingsToggle(
                            title: "High-recall (per reply)",
                            subtitle: "Opt in to deeper per-reply memory recall. Uses more of your context budget.",
                            isOn: $settingsManager.memoryHighRecallPerReply
                        )
                    }

                    if !settingsManager.memoryExtractionRemoteConfigEnabled {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignSystem.Colors.warning)
                                .padding(.top, 2)
                            Text("Memory extraction is temporarily disabled by your admin. Your chats are unaffected.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(DesignSystem.Colors.warning.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button(role: .destructive) {
                            memoryResetConfirm = true
                        } label: {
                            Text("Reset memory")
                                .font(DesignSystem.Typography.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(memoryService == nil)

                        if let memoryResetStatus {
                            Text(memoryResetStatus)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    SettingsToggle(
                        title: "Back up approved memories",
                        subtitle: "Off by default. When on, only memories you approve are replicated to your cloud vault, end-to-end sealed. Declining keeps every memory on this Mac.",
                        isOn: $settingsManager.memoryApprovedCloudBackupOptIn
                    )

                    deviceSyncRow

                    MemoryCloudModelsSection(settingsManager: settingsManager)

                    teamMemorySection

                    NavigationLink {
                        memoryReviewDestination
                    } label: {
                        SettingsDrillRow(
                            icon: "tray.full",
                            iconTint: DesignSystem.Colors.whimsy,
                            title: "Review pending memories",
                            subtitle: "Approve or reject what OpenBurnBar learned before it can be used"
                        )
                    }
                    .buttonStyle(.plain)

                    memoryHealthSection

                    memorySyncStatusSection
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                // Deep-link target for the Memory walkthrough's "Show me" and
                // Settings search: scrolls the Memory section into view and
                // paints the halo on arrival.
                .settingsAnchor(SettingsAnchor.indexingMemory)

                Divider().background(DesignSystem.Colors.border)

                // Drill via the shared page route (also a Look & Feel sidebar tab)
                // so Indexing does not mount the daemon probe inline.
                NavigationLink(value: SettingsPageRoute.aiInboxRoot) {
                    SettingsDrillRow(
                        icon: "tray.full.fill",
                        iconTint: DesignSystem.Colors.ember,
                        title: "AI Inbox",
                        subtitle: "Background analyst, egress, and cadence"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Spacing.lg)

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
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: DesignSystem.Spacing.sm)
                        Picker("", selection: $settingsManager.indexEmbeddingProvider) {
                            Text("On-device (Apple)").tag(IndexEmbeddingProviderID.appleNL)
                            Text("OpenAI").tag(IndexEmbeddingProviderID.openai)
                            Text("Hash (testing only)").tag(IndexEmbeddingProviderID.deterministic)
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 140, maxWidth: 220)
                    }

                    if settingsManager.indexEmbeddingProvider == .openai {
                        HStack {
                            Text("OpenAI model")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            Picker("", selection: $settingsManager.indexOpenAIModel) {
                                ForEach(OpenAIEmbeddingProvider.supportedModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: 140, maxWidth: 260)
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
                    } else if settingsManager.indexEmbeddingProvider == .appleNL {
                        Text("Apple's on-device sentence model embeds your index locally. No network, no API key, nothing leaves this Mac.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    } else {
                        Text("Seeded-hash vectors for tests and CI. Not semantic — similar sentences do not land near each other. Prefer On-device (Apple) for real search.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    HStack {
                        Text("Index version")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: DesignSystem.Spacing.sm)
                        Picker("", selection: $settingsManager.preferredIndexEmbeddingVersionID) {
                            Text("Automatic").tag("")
                            ForEach(embeddingVersions) { version in
                                Text(embeddingVersionMenuLabel(version))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .tag(version.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 140, maxWidth: 320)
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
                            subtitle: "Sends the query and top candidate passages to the selected provider for a second-pass relevance score.",
                            isOn: $settingsManager.crossEncoderRerankEnabled
                        )

                        if settingsManager.crossEncoderRerankEnabled {
                            HStack {
                                Text("Provider")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Picker("", selection: $settingsManager.crossEncoderProvider) {
                                    ForEach(CrossEncoderProviderID.allCases) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220)
                            }

                            HStack {
                                Text("Model")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Picker("", selection: $settingsManager.crossEncoderModel) {
                                    ForEach(CrossEncoderCatalog.modelOptions(for: settingsManager.crossEncoderProvider)) { option in
                                        Text(option.displayName).tag(option.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 240)
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

                            Text(settingsManager.crossEncoderProvider.requirementDescription)
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
            // Keychain + selection first (cheap), then stagger DB fan-out so the
            // Indexing screen does not stampede MainActor bookkeeping with the
            // AI Inbox daemon probe that also mounts on this page.
            refreshOpenAIKey()
            normalizeCrossEncoderSelection()
            refreshStorage()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                refreshSourceArtifactCount()
                refreshSearchCounts()
                try? await Task.sleep(nanoseconds: 50_000_000)
                refreshHealth()
                refreshEmbeddingLineage()
            }
            refreshDeviceSyncEntitlement()
        }
        .onChange(of: deviceSyncEntitlement.cloudTier) { _, _ in
            refreshDeviceSyncEntitlement()
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, newValue in
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "conversation_indexing",
                "new_value": .bool(newValue)
            ])
            if !newValue {
                scrubParserConversationCaches()
            }
            refreshStorage()
            refreshSourceArtifactCount()
            refreshSearchCounts()
            refreshHealth()
            refreshEmbeddingLineage()
        }
        .onChange(of: settingsManager.cliAssistantAllowed) { _, newValue in
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "cli_assistant",
                "new_value": .bool(newValue)
            ])
        }
        .onChange(of: settingsManager.indexEmbeddingProvider) { _, newValue in
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "index_embedding_provider",
                "new_value": .string(newValue.rawValue)
            ])
            reembedStatusMessage = nil
            reembedErrorMessage = nil
            refreshOpenAIKey()
        }
        .onChange(of: settingsManager.indexOpenAIModel) { _, _ in
            reembedStatusMessage = nil
            reembedErrorMessage = nil
        }
        .onChange(of: settingsManager.crossEncoderProvider) { _, _ in
            normalizeCrossEncoderSelection()
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
                Task { @MainActor in
                    do {
                        try await dataStore.deleteAllIndexedConversations()
                        deleteErrorMessage = nil
                        refreshStorage()
                        refreshSourceArtifactCount()
                        refreshSearchCounts()
                        refreshHealth()
                        refreshEmbeddingLineage()
                    } catch {
                        deleteErrorMessage = "Failed to delete indexed conversations: \(error.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Token usage totals are kept. Only locally indexed transcripts are removed.")
        }
        .confirmationDialog(
            "Reset all memories?",
            isPresented: $memoryResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { @MainActor in
                    do {
                        let service = MemorySettingsService()
                        let scope = MemorySettingsService.resetScope(userID: accountManager.userID)
                        let eventID = try await service.resetAllMemories(memoryService: memoryService, scope: scope)
                        guard eventID != nil else {
                            memoryResetStatus = "Memory reset is unavailable until the memory backend is connected."
                            return
                        }
                        memoryResetStatus = "Memories reset. Your chats are untouched."
                    } catch {
                        memoryResetStatus = "Failed to reset memories: \(error.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes learned preferences from the memory store. Chat transcripts and token usage are not affected.")
        }
    }

    // MARK: - Private Methods

    private func refreshStorage() {
        Task {
            let bytes = (try? await dataStore.approximateConversationStorageBytes()) ?? 0
            await MainActor.run {
                storageBytes = bytes
            }
        }
    }

    private func scrubParserConversationCaches() {
        Task.detached(priority: .utility) {
            let options = OpenBurnBarCore.LogParseOptions.usageAccounting()
            OpenBurnBarCore.ParserConversationCacheScrubber().scrubKnownParserCaches()
            _ = try? await CodexParser().parse(options: options)
            _ = try? await ClaudeCodeParser().parse(options: options)
            _ = try? await FactoryDroidParser().parse(options: options)
            for parser in [
                (pattern: "zai", provider: AgentProvider.zai),
                (pattern: "minimax", provider: .minimax),
                (pattern: "ollama", provider: .ollama)
            ] {
                _ = try? await ModelFilterParser(
                    modelPattern: parser.pattern,
                    provider: parser.provider
                ).parse(options: options)
            }
        }
    }

    private func refreshSourceArtifactCount() {
        Task {
            let sourceCount = (try? await dataStore.countSourceArtifacts()) ?? 0
            let conversations = (try? await dataStore.countConversations()) ?? 0
            await MainActor.run {
                sourceArtifactCount = sourceCount
                conversationCount = conversations
            }
        }
    }

    private func refreshSearchCounts() {
        Task { @MainActor in
            projectedDocumentCountValue = (try? await dataStore.countSearchDocuments()) ?? 0
            indexedChunkCountValue = (try? await dataStore.countSearchChunks()) ?? 0
        }
    }

    private func refreshHealth() {
        let service = RetrievalHealthService(dataStore: dataStore)
        Task { @MainActor in
            retrievalHealthSnapshot = await service.snapshot(
                indexingEnabled: settingsManager.conversationIndexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable
            )
        }
    }

    private func refreshEmbeddingLineage() {
        Task { @MainActor in
            embeddingModels = (try? await dataStore.fetchEmbeddingModels()) ?? []
            embeddingVersions = (try? await dataStore.fetchEmbeddingVersions()) ?? []
            embeddedChunkCountValue = (try? await dataStore.countChunkEmbeddings()) ?? 0
        }
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
        Task { @MainActor in
            do {
                try await ProjectionPipelineService.makeConfigured(
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
    }

    private func normalizeCrossEncoderSelection() {
        let normalized = CrossEncoderCatalog.normalizedModel(
            settingsManager.crossEncoderModel,
            provider: settingsManager.crossEncoderProvider
        )
        if settingsManager.crossEncoderModel != normalized {
            settingsManager.crossEncoderModel = normalized
        }
    }

    // MARK: - Computed Properties

    private var projectedDocumentCount: Int {
        projectedDocumentCountValue
    }

    private var indexedChunkCount: Int {
        indexedChunkCountValue
    }

    private var embeddedChunkCount: Int {
        embeddedChunkCountValue
    }

    private var indexableSourceCount: Int {
        conversationCount + sourceArtifactCount
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
            var parts = ["\(retrievalHealthSnapshot.semanticPipeline.indexedVectorCount) vectors are available for semantic ranking."]
            if let state = retrievalHealthSnapshot.semanticPipeline.snapshotState, state.isEmpty == false {
                parts.append("Snapshot: \(state).")
            }
            if let bytes = retrievalHealthSnapshot.semanticPipeline.snapshotFileBytes, bytes > 0 {
                parts.append("Disk: \(formatBytes(bytes)).")
            }
            return parts.joined(separator: " ")
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

    private var chatContentBackupSubtitle: String {
        if settingsManager.chatThreadContentCloudBackupEnabled {
            return "OpenBurnBar Assistant thread titles, previews, and messages are included in cloud backup."
        }
        return "Cloud backup stores chat thread counts and dates only. Message text stays local until you enable this."
    }

    private var chatContentBackupBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.chatThreadContentCloudBackupEnabled },
            set: { enabled in
                settingsManager.chatThreadContentCloudBackupEnabled = enabled
                settingsManager.chatThreadContentCloudBackupConsentShown = true
            }
        )
    }

    /// Pushes the live Data Vault tier into the settings coordinator's
    /// non-persisted entitlement snapshot. Idempotent — safe from `.onAppear`
    /// and every `.onChange(of: deviceSyncEntitlement.cloudTier)` firing.
    /// `MemoryCloudSyncDomain` refreshes the same lever on every sync cycle, so
    /// the pull's gate does not depend on this view having appeared.
    private func refreshDeviceSyncEntitlement() {
        deviceSyncEntitlement.start()
        settingsManager.memoryDeviceSyncEntitlementSatisfied = deviceSyncIsUnlocked
    }

    /// The live Data Vault entitlement, resolved exactly the way
    /// `MemoryCloudModelsSection` resolves it for its own veil.
    private var deviceSyncIsUnlocked: Bool {
        deviceSyncEntitlement.cloudTier.satisfies(Self.deviceSyncGatedFeature.requiredTier)
    }

    /// Team memory (memory program D16). Same entitlement and the same veil as
    /// the device-sync row, because it is the same lane: `TeamMemorySyncGate`
    /// ANDs the whole personal device-sync gate — entitlement included — under
    /// every team, so a member below the tier could not sync a team even with
    /// the switch on. Showing them what the feature is beats a dead grey row.
    ///
    /// The model is built once, lazily, and only when a member is signed in:
    /// its first act is a roster READ, and issuing one for a signed-out window
    /// would be a network call nobody asked for.
    @ViewBuilder
    private var teamMemorySection: some View {
        Group {
            if deviceSyncIsUnlocked {
                if let teamMemoryModel {
                    TeamMemorySection(model: teamMemoryModel)
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                LockedFeatureVeil(
                    headline: TeamMemoryCopy.sectionTitle,
                    detail: TeamMemoryCopy.sectionSubtitle,
                    ctaLabel: "See Pro",
                    icon: "person.3.sequence.fill",
                    action: { showTeamMemoryUnlockSheet = true },
                    background: { Color.clear.frame(height: 0) }
                )
            }
        }
        .sheet(isPresented: $showTeamMemoryUnlockSheet) {
            FeatureUnlockSheet(feature: Self.deviceSyncGatedFeature)
        }
        .onAppear {
            guard teamMemoryModel == nil, accountManager.isSignedIn else { return }
            teamMemoryModel = Self.makeTeamMemoryModel(
                settingsManager: settingsManager,
                accountManager: accountManager,
                cloudSyncDomain: runtimeContext?.memoryCloudSyncDomain
            )
        }
    }

    /// Assembles the production seams. Kept `static` so it reads as wiring: the
    /// roster read, the four membership callables and the rotation sequence are
    /// each their own type, and the model holds no Firebase handle itself.
    ///
    /// `personalGateProvider` is the SCOPE, not the sub-toggle (PR 4 review L4).
    /// `MemoryDeviceSyncScope.current(...)` is the one computation of "may a
    /// remote memory reach this device right now" — the four personal memory
    /// levers ANDed with the account levers (Firebase available, signed in,
    /// account cloud sync on) — and it is exactly what `TeamMemorySyncGate`
    /// requires as `deviceSyncGateOpen && accountLeversOpen`. Passing
    /// `memoryDeviceSyncEnabled` alone let a member with account cloud sync off
    /// switch a team on and watch `TeamMemorySyncDomain.runCycle` return `.idle`
    /// with nothing on screen saying why.
    @MainActor
    private static func makeTeamMemoryModel(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncDomain: MemoryCloudSyncDomain?
    ) -> TeamMemorySectionModel {
        let gateway = CloudSyncFirestoreLiveGateway()
        let callables = FirebaseTeamRosterCallableClient()
        let uid = accountManager.currentUID
        let deviceId = accountManager.deviceId
        let keyRing = KeychainTeamVaultKeyRing()
        let rotator: TeamKeyRotating? = uid.map { uid in
            TeamVaultKeyRotator(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        // The join half of design §3(b)2. Nil while signed out, exactly like the
        // rotator: both wrap keys AS this account, and there is no account to
        // wrap as.
        let joinerKeys: TeamJoinerKeyIssuing? = uid.map { uid in
            TeamVaultJoinerKeyIssuer(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        // The FOUNDING half of design §3(b)1, and the one this wiring was missing
        // outright: `bootstrapTeamKeys` had no production caller, so a created
        // team never got a `teamVaultKey_v1` or a `teamSlugKey` on any Mac. Nil
        // while signed out for the same reason as the two above.
        let founderKeys: TeamFounderKeyBootstrapping? = uid.map { uid in
            TeamVaultFounderKeyBootstrapper(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        return TeamMemorySectionModel(
            roster: FirestoreTeamRosterDirectory(gateway: gateway),
            admin: FirebaseTeamMemoryAdministrator(),
            rotator: rotator,
            joinerKeys: joinerKeys,
            founderKeys: founderKeys,
            uidProvider: { accountManager.currentUID },
            personalGateProvider: {
                MemoryDeviceSyncScope.current(account: accountManager, settings: settingsManager).isOpen
            },
            remoteConfigProvider: {
                (
                    settingsManager.memoryTeamSyncRemoteConfigAllowed,
                    settingsManager.memoryTeamSyncRemoteConfigResolved
                )
            },
            optInProvider: { settingsManager.memoryTeamSyncEnabledTeamIDs },
            optInWriter: { settingsManager.memoryTeamSyncEnabledTeamIDs = $0 },
            // Read from the SAME Keychain ring the sync cycle and the
            // distributor use, so the row cannot report a readiness the lane
            // below it disagrees with.
            keyReadinessProvider: { detail in
                TeamKeyReadiness.resolve(ring: keyRing, detail: detail)
            },
            // The eager half of the leave (PR 4 review §3). Nil only when this
            // settings surface was built without a runtime context, in which
            // case there is no sync lane to invalidate and the next cycle — on
            // whichever process owns one — does it.
            invalidateTeamSync: { [weak cloudSyncDomain] teamID in
                await cloudSyncDomain?.invalidateTeamMemorySync(teamID: teamID)
            }
        )
    }

    /// "Sync memories to my other devices". Below the Data Vault tier the row
    /// sits behind `LockedFeatureVeil` with a real unlock path, mirroring
    /// `MemoryCloudModelsSection` — a member who cannot use the feature is shown
    /// what it is and how to get it, not a dead grey switch. The other two
    /// levers (the backup opt-in and the fleet ceiling) keep the plain disabled
    /// + explanatory-subtitle treatment, because those the member can resolve
    /// on this same screen or not at all.
    @ViewBuilder
    private var deviceSyncRow: some View {
        Group {
            if deviceSyncIsUnlocked {
                deviceSyncToggle
            } else {
                LockedFeatureVeil(
                    headline: "Sync memories to my other devices",
                    detail: "Pro. Approved memories your other signed-in devices backed up are pulled down onto this Mac, end-to-end sealed. BurnBar never sees them.",
                    ctaLabel: "See Pro",
                    icon: "arrow.triangle.2.circlepath",
                    action: { showDeviceSyncUnlockSheet = true },
                    background: { deviceSyncToggle.disabled(true) }
                )
            }
        }
        .settingsAnchor(SettingsAnchor.indexingMemoryDeviceSync)
        .sheet(isPresented: $showDeviceSyncUnlockSheet) {
            FeatureUnlockSheet(feature: Self.deviceSyncGatedFeature)
        }
    }

    /// The switch itself — off by default, and reading off whenever the
    /// effective gate is closed (sub-toggle off, backup opt-in off, the fleet
    /// ceiling closed, or no Data Vault entitlement) regardless of what the raw
    /// sub-toggle is persisted as, so a greyed-out switch never appears to
    /// silently be on.
    private var deviceSyncToggle: some View {
        SettingsToggle(
            title: "Sync memories to my other devices",
            subtitle: deviceSyncSubtitle,
            isOn: deviceSyncBinding
        )
        .disabled(!settingsManager.memoryDeviceSyncRowUnlocked)
    }

    private var deviceSyncSubtitle: String {
        // The fleet ceiling FIRST. `memoryApprovedCloudBackupEnabled` folds the
        // Remote Config ceiling into the user opt-in, so a fleet kill switch
        // used to render as "Turn on 'Back up approved memories' first" while
        // that toggle visibly read ON — telling the member to do something they
        // had already done and that would not have helped.
        if !settingsManager.memoryExtractionRemoteConfigEnabled {
            return "Temporarily unavailable — memory sync is paused for all OpenBurnBar users. Nothing you can change on this Mac affects it; it comes back on its own."
        }
        if !settingsManager.memoryApprovedCloudBackupEnabled {
            return "Turn on \"Back up approved memories\" first. Off by default — pulls your approved memories back down from your other signed-in devices too."
        }
        if !settingsManager.memoryDeviceSyncEntitlementSatisfied {
            return "Requires the Data Vault plan (Pro Max or Ultra). Off by default — pulls your approved memories back down from your other signed-in devices too."
        }
        return "Off by default. When on, approved memories your other signed-in devices backed up are pulled down and merged into this Mac's memory too."
    }

    private var deviceSyncBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.memoryDeviceSyncRowEnabled },
            set: { isOn in
                settingsManager.memoryDeviceSyncOptIn = isOn
                enforceDeviceSyncInboxScope()
            }
        )
    }

    /// Applies the member's decision to the inbox at once, rather than on the
    /// next sync tick. Turning device sync OFF withdraws consent for facts that
    /// are already parked and not yet merged, so those go now and the daemon's
    /// consent marker is withdrawn with them — a member who flips the switch off
    /// and immediately runs an agent must not have a pending drain land anyway.
    /// `MemoryCloudSyncDomain` enforces the same scope every cycle; this is the
    /// immediacy the switch itself promises.
    private func enforceDeviceSyncInboxScope() {
        guard let store = runtimeContext?.chatMemoryStore else { return }
        // Generation BEFORE scope — see `MemoryDeviceSyncInboxGuard.observeGeneration`.
        let observedGeneration = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        // The SAME computation `MemoryCloudSyncDomain.gateSnapshot()` uses, by
        // construction. Built here from `memoryDeviceSyncEnabled` alone, this
        // path published a fresh daemon consent marker for a member whose
        // ACCOUNT-wide cloud sync was off — pending remote facts could then
        // drain into the engine until the next refresh tick withdrew it.
        let scope = MemoryDeviceSyncScope.current(account: accountManager, settings: settingsManager)
        Task {
            do {
                try await MemoryDeviceSyncInboxGuard.enforce(
                    scope: scope,
                    observedGeneration: observedGeneration,
                    store: store
                )
            } catch {
                // The next sync tick enforces the same scope, so a failure here
                // delays the purge rather than losing it.
                AppLogger.sync.error(
                    "memory_device_sync_toggle_inbox_guard_failed",
                    metadata: ["error_type": String(describing: type(of: error))]
                )
            }
        }
    }

    // MARK: - Helper Views

    /// Per-project memory health, beside the pending-review link because they
    /// answer the same question from two sides: what is waiting for you, and
    /// what is wrong. Counters come from the local daemon over the existing
    /// `daemon.memory.analytics` RPC; every finding is one this Mac measured
    /// itself, and the card says so.
    ///
    /// The host picks its own subject from the projects the daemon has already
    /// recorded. Settings has no project scope of its own, and passing that
    /// absence down to the daemon would have it resolve its own working
    /// directory into a phantom project — see `ProjectMemoryHealthModel`.
    @ViewBuilder
    private var memoryHealthSection: some View {
        if let store = runtimeContext?.chatMemoryStore {
            ProjectMemoryHealthCardHost(
                store: store,
                daemonManager: runtimeContext?.daemonManager,
                accountUid: accountManager.userID
            )
            .settingsAnchor(SettingsAnchor.indexingMemoryHealth)
        }
    }

    /// Both transport cursors, the consent marker's age, and the inbox counts.
    ///
    /// Behind a disclosure because it is a diagnostic: it is the surface a
    /// member opens when memories are not arriving, and the numbers only mean
    /// anything next to the thresholds the row states. Every value is read from
    /// this Mac's own database — nothing here issues a network call or an RPC.
    @ViewBuilder
    private var memorySyncStatusSection: some View {
        if let store = runtimeContext?.chatMemoryStore {
            DisclosureGroup(isExpanded: $isMemorySyncStatusExpanded) {
                MemorySyncDebugRowHost(store: store, accountUid: accountManager.userID)
                    .padding(.top, DesignSystem.Spacing.sm)
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Memory sync status")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Text("Cursors, consent marker, parked inbox")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.22))
            )
            .settingsAnchor(SettingsAnchor.indexingMemorySyncStatus)
        }
    }

    /// Destination for the "Review pending memories" link. Builds the inbox over
    /// the shared `ControlPlaneStore` when the runtime context is wired; otherwise
    /// shows a graceful unavailable state so the link never dead-ends.
    @ViewBuilder
    private var memoryReviewDestination: some View {
        if let store = runtimeContext?.chatMemoryStore {
            MemoryReviewInboxHost(
                store: store,
                scope: MemoryScope(appID: "openburnbar"),
                userID: accountManager.userID
            )
            .id(ObjectIdentifier(store))
            .navigationTitle("Memory")
        } else {
            ContentUnavailableView(
                "Memory is unavailable",
                systemImage: "brain.head.profile",
                description: Text("The memory store is not ready yet. It activates once OpenBurnBar finishes starting up.")
            )
            .navigationTitle("Memory")
        }
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
