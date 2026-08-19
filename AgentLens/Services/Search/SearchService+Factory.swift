import Foundation
import OpenBurnBarCore

extension SearchService {
        @MainActor
        static func makeConversationSearchService(
            dataStore: DataStore,
            settingsManager: SettingsManager = .shared,
            accountManager: AccountManager = .shared,
            providerAPIKeyStore: ProviderAPIKeyStore = .shared,
            nowProvider: @escaping @Sendable () -> Date = { Date() }
        ) -> SearchService {
            let preferredVersionID = settingsManager.preferredIndexEmbeddingVersionIDValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let queryEmbedder = makeQueryEmbedder(
                selection: nil,
                providerAPIKeyStore: providerAPIKeyStore
            )
            return makeConversationSearchService(
                dataStore: dataStore,
                accountManager: accountManager,
                queryEmbedder: queryEmbedder,
                preferredVersionID: preferredVersionID?.isEmpty == false ? preferredVersionID : nil,
                settingsManager: settingsManager,
                providerAPIKeyStore: providerAPIKeyStore,
                nowProvider: nowProvider
            )
        }

        @MainActor
        static func makeConversationSearchServiceUsingStoredEmbeddings(
            dataStore: DataStore,
            settingsManager: SettingsManager = .shared,
            accountManager: AccountManager = .shared,
            providerAPIKeyStore: ProviderAPIKeyStore = .shared,
            nowProvider: @escaping @Sendable () -> Date = { Date() }
        ) async -> SearchService {
            let selection = await resolvedEmbeddingSelection(
                dataStore: dataStore,
                preferredEmbeddingVersionID: settingsManager.preferredIndexEmbeddingVersionIDValue,
                configuredProvider: settingsManager.indexEmbeddingProvider
            )
            let preferredVersionID = selection?.version.id
            let queryEmbedder = makeQueryEmbedder(
                selection: selection,
                providerAPIKeyStore: providerAPIKeyStore
            )
            return makeConversationSearchService(
                dataStore: dataStore,
                accountManager: accountManager,
                queryEmbedder: queryEmbedder,
                preferredVersionID: preferredVersionID,
                settingsManager: settingsManager,
                providerAPIKeyStore: providerAPIKeyStore,
                nowProvider: nowProvider
            )
        }

        @MainActor
        private static func makeConversationSearchService(
            dataStore: DataStore,
            accountManager: AccountManager,
            queryEmbedder: (any QueryEmbeddingProviding)?,
            preferredVersionID: String?,
            settingsManager: SettingsManager,
            providerAPIKeyStore: ProviderAPIKeyStore,
            nowProvider: @escaping @Sendable () -> Date
        ) -> SearchService {
            let semanticProvider = queryEmbedder.map { embedder in
                VectorSemanticCandidateProvider(
                    dataStore: dataStore,
                    queryEmbedder: embedder,
                    embeddingVersionID: preferredVersionID
                )
            }

            // Construct reranker if cross-encoder is enabled and API key is available
            let reranker: RetrievalRerankProviding? = Self.makeReranker(
                settingsManager: settingsManager,
                providerAPIKeyStore: providerAPIKeyStore
            )

            return SearchService(
                dataStore: dataStore,
                semanticProvider: semanticProvider,
                reranker: reranker,
                sharedArtifactAccessContextProvider: { @MainActor @Sendable in
                    SearchService.defaultSharedArtifactAccessContext(accountManager: accountManager)
                },
                nowProvider: nowProvider
            )
        }

        @MainActor
        private static func makeReranker(
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

            case .ollama:
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
            }
        }

        @MainActor
        private static func resolveCrossEncoderAPIKey(
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
                let raw = keychain.credentialIfPresent(
                    for: account,
                    allowUserInteraction: false,
                    event: "cross_encoder_connector_key_read_failed"
                )
                return nonEmpty(raw)
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
            case .ollama:
                return nonEmpty(providerAPIKeyStore.apiKey(for: "ollama"))
                    ?? nonEmpty(env["OLLAMA_API_KEY"])
            case .codexCLI, .claudeCLI, .hermes:
                return nil
            }
        }

        @MainActor
        /// Returns `nil` when no embedder can query the SELECTED lineage's vector
        /// space. Callers must then run without a semantic provider: lexical search
        /// still answers, which is honest, where querying the wrong space returns
        /// confident nonsense.
        private static func makeQueryEmbedder(
            selection: (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)?,
            providerAPIKeyStore: ProviderAPIKeyStore
        ) -> (any QueryEmbeddingProviding)? {
            guard let selection else {
                return DeterministicQueryEmbeddingProvider()
            }

            if selection.model.provider.caseInsensitiveCompare(NLEmbeddingProvider.providerName) == .orderedSame {
                // Query vectors must live in the same space as the indexed chunks.
                // The dimension guard matters: an OS update can change the NL model,
                // and a mismatched query vector is a silent relevance failure. On
                // mismatch we fall through to the descriptor-mimicking deterministic
                // embedder (dimensionally consistent with the OLD index) and let the
                // projection pipeline's drift re-embed converge the index.
                if let nl = NLEmbeddingProvider(
                    chunkerVersion: selection.version.chunkerVersion,
                    promptVersion: selection.version.promptVersion
                ), nl.descriptor.dimensions == selection.model.dimensions {
                    return nl
                }
                AppLogger.search.error(
                    "search_query_embedder_nl_unavailable_or_dimension_drift",
                    metadata: ["expectedDimensions": "\(selection.model.dimensions)"]
                )
                // DISABLE semantic search for this lineage rather than substituting a
                // descriptor-mimicking deterministic embedder. Matching dimensions and
                // metadata do NOT put hashed vectors in the Apple model's space, so the
                // substitute produced meaningless rankings that looked authoritative.
                // Lexical results are the honest answer until the drift re-embed lands.
                return nil
            }

            if selection.model.provider.caseInsensitiveCompare("openai") == .orderedSame {
                do {
                    return try OpenAIEmbeddingProvider(
                        apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                        modelName: selection.model.modelName,
                        versionTag: selection.version.versionTag,
                        chunkerVersion: selection.version.chunkerVersion,
                        normalizationVersion: selection.version.normalizationVersion,
                        promptVersion: selection.version.promptVersion
                    )
                } catch {
                    // The selection names the OpenAI provider, yet the real provider
                    // could not be constructed (e.g. an unsupported model name from a
                    // stale/foreign projection record). Falling through to the
                    // deterministic embedder keeps search alive, but query vectors then
                    // live in a DIFFERENT space than the OpenAI-indexed chunk vectors —
                    // a silent relevance failure. Surface it so the degradation is
                    // observable rather than swallowed by the old `try?`.
                    AppLogger.search.error(
                        "search_query_embedder_openai_construction_failed",
                        metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                    )
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

        /// Maps the configured index lane to the provider string its embedder
        /// stamps into `embedding_models.provider`, so version resolution can
        /// prefer the space the index is actually being written in.
        private static func expectedModelProvider(for provider: IndexEmbeddingProviderID) -> String {
            switch provider {
            case .appleNL: NLEmbeddingProvider.providerName
            case .openai: "openai"
            case .deterministic: "openburnbar"
            }
        }

        private static func resolvedEmbeddingSelection(
            dataStore: DataStore,
            preferredEmbeddingVersionID: String?,
            configuredProvider: IndexEmbeddingProviderID? = nil
        ) async -> (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)? {
            // A projection-store fault (locked/corrupt DB, schema fault) is NOT the same
            // as "no embedding models indexed yet": the former should be observable, the
            // latter is a normal empty state. The old `try?` collapsed both into a silent
            // nil, which downgrades search to the deterministic embedder with no version
            // pinning and no trace. Convert reads to do/catch+log so a real DB fault is
            // surfaced while preserving the graceful skip-to-deterministic behavior.
            let models: [EmbeddingModelRecord]
            do {
                models = try await dataStore.fetchEmbeddingModels()
            } catch {
                AppLogger.dataStore.error(
                    "search_embedding_models_fetch_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
                return nil
            }
            guard models.isEmpty == false else {
                return nil
            }

            let versions: [EmbeddingVersionRecord]
            do {
                versions = try await dataStore.fetchEmbeddingVersions()
            } catch {
                AppLogger.dataStore.error(
                    "search_embedding_versions_fetch_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
                return nil
            }
            guard versions.isEmpty == false else {
                return nil
            }

            let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            let preferred = preferredEmbeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)

            // `isActive` is scoped per model, so after an embedder migration two
            // models can each hold an active version (e.g. the retired hash
            // lineage and the current appleNL lineage). Prefer the active version
            // whose model matches the lane the index is CONFIGURED to write —
            // otherwise a stale lineage can win the tie and query vectors land in
            // a different space than the chunks they search against.
            let configuredActive: EmbeddingVersionRecord? = configuredProvider.flatMap { provider in
                let expected = expectedModelProvider(for: provider)
                return versions.first(where: { version in
                    version.isActive
                        && modelByID[version.modelID]?.provider.caseInsensitiveCompare(expected) == .orderedSame
                })
            }

            let version = versions.first(where: { $0.id == preferred })
                ?? configuredActive
                ?? versions.first(where: \.isActive)
                ?? versions.first

            guard let version, let model = modelByID[version.modelID] else {
                return nil
            }
            return (model, version)
        }

        @MainActor private static func defaultSharedArtifactAccessContext(accountManager: AccountManager) -> SharedArtifactAccessContext? {
            guard
                let userID = accountManager.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
                userID.isEmpty == false
            else {
                return nil
            }
            return SharedArtifactAccessContext.defaultScope(for: userID)
        }
}
