import Foundation
import OpenBurnBarCore

// MARK: - Factory / construction

extension SearchService {

    @MainActor
    static func makeConversationSearchService(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        nowProvider: @escaping () -> Date = { Date() }
    ) -> SearchService {
        let selection = resolvedEmbeddingSelection(
            dataStore: dataStore,
            preferredEmbeddingVersionID: settingsManager.preferredIndexEmbeddingVersionIDValue
        )
        let preferredVersionID = selection?.version.id
        let queryEmbedder = makeQueryEmbedder(
            selection: selection,
            providerAPIKeyStore: providerAPIKeyStore
        )
        let semanticProvider = VectorSemanticCandidateProvider(
            dataStore: dataStore,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: preferredVersionID
        )

        // Construct reranker if cross-encoder is enabled and API key is available
        let reranker: RetrievalRerankProviding? = Self.makeReranker(
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )

        return SearchService(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            reranker: reranker,
            sharedArtifactAccessContextProvider: SearchService.defaultSharedArtifactAccessContext,
            nowProvider: nowProvider
        )
    }

    @MainActor
    internal static func makeReranker(
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> RetrievalRerankProviding? {
        guard settingsManager.crossEncoderRerankEnabled else {
            return nil
        }

        let provider = settingsManager.crossEncoderProvider
        let model = CrossEncoderCatalog.normalizedModel(
            settingsManager.crossEncoderModel,
            provider: provider
        )

        switch provider {
        case .codexCLI:
            guard settingsManager.cliAssistantAllowed else {
                return nil
            }
            return CLICrossEncoderReranker(
                provider: .codex,
                modelName: model,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .claudeCLI:
            guard settingsManager.cliAssistantAllowed else {
                return nil
            }
            return CLICrossEncoderReranker(
                provider: .claude,
                modelName: model,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .hermes:
            guard let baseURL = provider.baseURL else {
                return nil
            }
            return OpenAICompatibleCrossEncoderReranker(
                apiKey: "",
                requiresAPIKey: false,
                modelName: model,
                baseURL: baseURL,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .minimax, .zai, .openrouter:
            guard
                let apiKey = resolveCrossEncoderAPIKey(
                    for: provider,
                    providerAPIKeyStore: providerAPIKeyStore
                ),
                let baseURL = provider.baseURL
            else {
                return nil
            }

            var extraHeaders: [String: String] = [:]
            if provider.includesOpenRouterHeaders {
                extraHeaders["X-Title"] = "OpenBurnBar"
            }

            return OpenAICompatibleCrossEncoderReranker(
                apiKey: apiKey,
                modelName: model,
                baseURL: baseURL,
                extraHeaders: extraHeaders,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )
        }
    }

    @MainActor
    internal static func resolveCrossEncoderAPIKey(
        for provider: CrossEncoderProviderID,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.isEmpty == false else {
                return nil
            }
            return trimmed
        }

        func cursorConnectorKey(for account: String) -> String? {
            let keychain = KeychainStore()
            let raw = try? keychain.string(for: account, allowUserInteraction: false)
            return nonEmpty(raw ?? nil)
        }

        let env = ProcessInfo.processInfo.environment

        switch provider {
        case .openrouter:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "openrouter"))
                ?? nonEmpty(env["OPENROUTER_API_KEY"])
        case .minimax:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "minimax"))
                ?? cursorConnectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(env["MINIMAX_API_KEY"])
        case .zai:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "zai"))
                ?? cursorConnectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(env["ZAI_API_KEY"])
        case .codexCLI, .claudeCLI, .hermes:
            return nil
        }
    }

    @MainActor
    internal static func makeQueryEmbedder(
        selection: (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)?,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> any QueryEmbeddingProviding {
        guard let selection else {
            return DeterministicQueryEmbeddingProvider()
        }

        if selection.model.provider.caseInsensitiveCompare("openai") == .orderedSame {
            if let provider = try? OpenAIEmbeddingProvider(
                apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                modelName: selection.model.modelName,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            ) {
                return provider
            }
        }

        return DeterministicQueryEmbeddingProvider(
            embedder: DeterministicFakeEmbeddingProvider(
                provider: selection.model.provider,
                modelName: selection.model.modelName,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            )
        )
    }

    internal static func resolvedEmbeddingSelection(
        dataStore: DataStore,
        preferredEmbeddingVersionID: String?
    ) -> (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)? {
        guard
            let models = try? dataStore.fetchEmbeddingModels(),
            models.isEmpty == false,
            let versions = try? dataStore.fetchEmbeddingVersions(),
            versions.isEmpty == false
        else {
            return nil
        }

        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let preferred = preferredEmbeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versions.first(where: { $0.id == preferred })
            ?? versions.first(where: \.isActive)
            ?? versions.first

        guard let version, let model = modelByID[version.modelID] else {
            return nil
        }
        return (model, version)
    }

    @MainActor internal static func defaultSharedArtifactAccessContext() -> SharedArtifactAccessContext? {
        guard
            let userID = AccountManager.shared.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
            userID.isEmpty == false
        else {
            return nil
        }
        return SharedArtifactAccessContext.defaultScope(for: userID)
    }

    /// `nonisolated` because `dataStore` is an immutable `let` and `fetchConversations`
    /// uses GRDB's synchronous `read` — no actor isolation needed.
}
