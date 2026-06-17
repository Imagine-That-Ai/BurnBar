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
                preferredEmbeddingVersionID: settingsManager.preferredIndexEmbeddingVersionIDValue
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
            queryEmbedder: any QueryEmbeddingProviding,
            preferredVersionID: String?,
            settingsManager: SettingsManager,
            providerAPIKeyStore: ProviderAPIKeyStore,
            nowProvider: @escaping @Sendable () -> Date
        ) -> SearchService {
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
        private static func makeQueryEmbedder(
            selection: (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)?,
            providerAPIKeyStore: ProviderAPIKeyStore
        ) -> any QueryEmbeddingProviding {
            guard let selection else {
                return DeterministicQueryEmbeddingProvider()
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

        private static func resolvedEmbeddingSelection(
            dataStore: DataStore,
            preferredEmbeddingVersionID: String?
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
            let version = versions.first(where: { $0.id == preferred })
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
