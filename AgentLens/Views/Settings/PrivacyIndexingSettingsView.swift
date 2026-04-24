import SwiftUI

// MARK: - Privacy & Indexing Settings View

/// Settings view for privacy, indexing, and embedding configuration
struct PrivacyIndexingSettingsView: View {
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
                    subtitle: "Lets OpenBurnBar run your local `claude` or `codex` binary for chat and reranking. You can revoke this anytime.",
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
                            Text("OpenBurnBar Local").tag(IndexEmbeddingProviderID.deterministic)
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
                        Text("OpenBurnBar Local uses the built-in deterministic embedder. It is fully local and requires no network or API key.")
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
            refreshStorage()
            refreshHealth()
            refreshEmbeddingLineage()
            refreshOpenAIKey()
            normalizeCrossEncoderSelection()
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

    // MARK: - Private Methods

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

    // MARK: - Helper Views

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
