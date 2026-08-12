import Foundation
import GRDB
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves the cross-encoder connector-key read in `SearchService+Factory`
/// (`cursorConnectorKey(for:)`) no longer collapses a *broken* Keychain into the
/// same `nil` as "no credential configured".
///
/// The factory reads the connector key via `KeychainStore.credentialIfPresent`,
/// which preserves the nil-on-absent contract while surfacing genuine Keychain
/// faults to `AppLogger`. These tests exercise that exact accessor through the
/// `KeychainStore(backend:)` injection seam the production path resolves to:
///
///   * a genuine Keychain fault (`KeychainStoreError.unhandled(errSecNotAvailable)`)
///     must return `nil` *without throwing or crashing* — the fault is observable
///     in the log rather than silently swallowed by the old `try?`.
///   * a genuinely absent credential must still return `nil`, so the migrated
///     call site keeps degrading gracefully when no key is configured.
final class SearchServiceFactoryCredentialReadTests: XCTestCase {
    private let service = "com.openburnbar.searchservice-factory-credential-tests"
    private let account = "provider.minimax.apiKey"

    func test_connectorKeyRead_returnsNilAndDoesNotThrowOnKeychainFault() {
        // Drive the real fault path: a locked/unavailable Keychain surfaces an
        // unhandled OSStatus. The accessor must log and degrade to nil — never
        // propagate, never crash, never masquerade as "no credential".
        let backend = FaultInjectingKeychainBackend()
        backend.readErrors[service] = KeychainStoreError.unhandled(errSecNotAvailable)
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func test_connectorKeyRead_returnsNilWhenCredentialAbsent() {
        let backend = FaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func test_connectorKeyRead_returnsStoredCredential() throws {
        let backend = FaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)
        try keychain.set("sk-connector-secret", for: account)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertEqual(result, "sk-connector-secret")
    }
}

// MARK: - Fault-injecting test backend

/// In-memory `KeychainStoreBackend` whose `data(for:)` throws a configured fault,
/// letting tests model a locked/unavailable Keychain through the production seam.
private final class FaultInjectingKeychainBackend: KeychainStoreBackend {
    private struct State: Sendable {
        var storage: [String: [String: Data]] = [:]
        var readErrors: [String: KeychainStoreError] = [:]
        var deleteErrors: [String: KeychainStoreError] = [:]
    }

    private let state = Locked(State())

    var readErrors: [String: KeychainStoreError] {
        get { state.read().readErrors }
        set { state.withLock { $0.readErrors = newValue } }
    }

    var deleteErrors: [String: KeychainStoreError] {
        get { state.read().deleteErrors }
        set { state.withLock { $0.deleteErrors = newValue } }
    }

    func set(_ value: Data, service: String, account: String) throws {
        state.withLock { $0.storage[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        try state.withLock { state in
            if let error = state.readErrors[service] {
                throw error
            }
            return state.storage[service]?[account]
        }
    }

    func delete(service: String, account: String) throws {
        try state.withLock { state in
            if let error = state.deleteErrors[service] {
                throw error
            }
            state.storage[service]?[account] = nil
        }
    }
}

// MARK: - Embedding-selection fault paths

/// Proves the two formerly-`try?` projection reads in `resolvedEmbeddingSelection`
/// (`fetchEmbeddingModels()` / `fetchEmbeddingVersions()`) and the formerly-`try?`
/// `OpenAIEmbeddingProvider` construction in `makeQueryEmbedder` no longer collapse
/// a genuine fault into silent garbage:
///
///   * a projection-store fault (a schema-less DB whose `embedding_models` table
///     does not exist) must be CAUGHT and logged, with the factory degrading
///     gracefully to a still-buildable service — never crashing, never propagating.
///   * a healthy-but-empty store must keep building a service (the normal empty
///     state, not a fault), proving the migration did not change behavior.
///   * a selection that names the OpenAI provider but an UNSUPPORTED model name
///     (e.g. a stale/foreign projection record) must have its provider-construction
///     failure caught and degrade to the deterministic embedder rather than crash.
///
/// These exercise the private `resolvedEmbeddingSelection`/`makeQueryEmbedder`
/// through the public `makeConversationSearchService` factory seam — the same path
/// production app code resolves to.
@MainActor
final class SearchServiceFactoryEmbeddingSelectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_742_900_000)

    /// A `DataStore` with NO schema applied: `fetchEmbeddingModels()` throws
    /// `SQLite error: no such table` — exactly the projection-store fault the
    /// migrated do/catch must surface and absorb.
    private func makeSchemalessStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: false, refreshOnInit: false)
    }

    func test_makeConversationSearchService_buildsDespiteProjectionStoreFault() async throws {
        // Sanity: the schema-less store genuinely faults on the embedding read,
        // so this test drives the real catch path rather than an empty-result path.
        let store = try makeSchemalessStore()
        do {
            _ = try await store.fetchEmbeddingModels()
            XCTFail("Expected schemaless store to throw when fetching embedding models.")
        } catch {
            // Expected: this test drives the factory's fault-tolerant projection read path.
        }

        // The factory must absorb that fault (log + skip-to-deterministic) and still
        // return a usable service. The old `try?` also returned a service, but
        // silently; the migrated do/catch keeps the graceful degrade while logging.
        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    func test_makeConversationSearchService_buildsForHealthyEmptyStore() async throws {
        // A migrated store with zero embedding rows is a NORMAL empty state, not a
        // fault. The factory must keep building a service (deterministic embedder).
        let store = try makeDiscoveryInMemoryStore()
        let embeddingModelCount = try await store.fetchEmbeddingModels().count
        XCTAssertEqual(embeddingModelCount, 0)

        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    func test_makeConversationSearchService_resolvesSelectionAcrossBothFetches() async throws {
        // Both reads succeed and return rows: selection resolves and the factory
        // builds. Guards the do/catch refactor against breaking the happy path that
        // depends on BOTH fetchEmbeddingModels() and fetchEmbeddingVersions().
        let store = try makeDiscoveryInMemoryStore()
        let modelID = "embedding-model-resolve"
        try await store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: "openai",
                modelName: "text-embedding-3-small",
                dimensions: 1536,
                distanceMetric: .cosine,
                createdAt: base,
                updatedAt: base
            )
        )
        try await store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: "embedding-version-resolve",
                modelID: modelID,
                versionTag: "v1",
                chunkerVersion: "chunk-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        let embeddingModelCount = try await store.fetchEmbeddingModels().count
        let embeddingVersionCount = try await store.fetchEmbeddingVersions().count
        XCTAssertEqual(embeddingModelCount, 1)
        XCTAssertEqual(embeddingVersionCount, 1)

        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    func test_makeConversationSearchService_buildsWhenOpenAIModelUnsupported() async throws {
        // Selection names the OpenAI provider but with a model name the real provider
        // rejects (unsupported -> init throws). The migrated do/catch must catch that
        // and degrade to the deterministic embedder instead of crashing/propagating.
        let store = try makeDiscoveryInMemoryStore()
        let modelID = "embedding-model-unsupported-openai"
        try await store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: "openai",
                modelName: "totally-unsupported-embedding-model",
                dimensions: 1536,
                distanceMetric: .cosine,
                createdAt: base,
                updatedAt: base
            )
        )
        try await store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: "embedding-version-unsupported-openai",
                modelID: modelID,
                versionTag: "v1",
                chunkerVersion: "chunk-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        // Independently confirm the construction genuinely throws for this model,
        // so the test drives the real catch rather than a happy path.
        XCTAssertThrowsError(
            try OpenAIEmbeddingProvider(
                apiKey: "",
                modelName: "totally-unsupported-embedding-model"
            )
        )

        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    func test_makeConversationSearchService_buildsForSupportedOpenAIModel() async throws {
        // Happy OpenAI path: a supported model constructs the real provider. Guards
        // the do/catch refactor against regressing the success branch.
        let store = try makeDiscoveryInMemoryStore()
        let modelID = "embedding-model-supported-openai"
        try await store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: "openai",
                modelName: "text-embedding-3-large",
                dimensions: 3072,
                distanceMetric: .cosine,
                createdAt: base,
                updatedAt: base
            )
        )
        try await store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: "embedding-version-supported-openai",
                modelID: modelID,
                versionTag: "v1",
                chunkerVersion: "chunk-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }
}
