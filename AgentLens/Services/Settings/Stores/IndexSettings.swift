import Foundation

// MARK: - Index Settings

@Observable
@MainActor
final class IndexSettings {
    private let persistence: SettingsPersistenceCoordinator

    var conversationIndexingEnabled: Bool = false {
        didSet { persistence.set(conversationIndexingEnabled, forKey: "conversationIndexingEnabled") }
    }

    var restrictedLogAccess: Bool = true {
        didSet { persistence.set(restrictedLogAccess, forKey: "restrictedLogAccess") }
    }

    /// Encryption-at-rest is mandatory (B-DATA-1). These read-only compatibility
    /// values keep older presentation code source-compatible while preventing any
    /// settings caller from recreating the retired plaintext opt-outs.
    private(set) var databaseEncryptionEnabled: Bool = true
    private(set) var plaintextDatabaseAcknowledged: Bool = false

    var preferredIndexEmbeddingVersionID: String = "" {
        didSet { persistence.set(preferredIndexEmbeddingVersionID, forKey: "preferredIndexEmbeddingVersionID") }
    }

    var indexEmbeddingProvider: IndexEmbeddingProviderID = .appleNL {
        didSet { persistence.set(indexEmbeddingProvider, forKey: "indexEmbeddingProvider") }
    }

    var indexOpenAIModel: String = "text-embedding-3-small" {
        didSet { persistence.set(indexOpenAIModel, forKey: "indexOpenAIModel") }
    }

    var conversationIndexingConsentShown: Bool = false {
        didSet { persistence.set(conversationIndexingConsentShown, forKey: "conversationIndexingConsentShown") }
    }

    var preferredIndexEmbeddingVersionIDValue: String? {
        let trimmed = preferredIndexEmbeddingVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.conversationIndexingConsentShown = persistence.bool(forKey: "conversationIndexingConsentShown")
        if persistence.objectExists(forKey: "conversationIndexingEnabled") {
            self.conversationIndexingEnabled = persistence.bool(forKey: "conversationIndexingEnabled")
        } else {
            self.conversationIndexingEnabled = false
        }
        if persistence.objectExists(forKey: "restrictedLogAccess") {
            self.restrictedLogAccess = persistence.bool(forKey: "restrictedLogAccess")
        } else {
            self.restrictedLogAccess = true
        }
        self.databaseEncryptionEnabled = true
        self.plaintextDatabaseAcknowledged = false
        persistence.set(true, forKey: "databaseEncryptionEnabled")
        persistence.removeObject(forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey)
        persistence.removeObject(forKey: "plaintextDatabaseAcknowledged")
        self.preferredIndexEmbeddingVersionID = persistence.string(forKey: "preferredIndexEmbeddingVersionID")
        // One-shot upgrade: `deterministic` (the seeded-hash CI embedder) was the
        // silent default for every install before the appleNL provider existed, so a
        // stored `deterministic` value was never a real user choice. Upgrade it once
        // to on-device semantic embeddings; after the migration flag is set, an
        // explicit re-selection of `deterministic` in Settings sticks. The projection
        // pipeline notices the embedding-version drift on its next sweep and
        // re-embeds automatically.
        let nlMigrationKey = "indexEmbeddingProviderNLMigration.v1"
        let nlMigrationDone = persistence.bool(forKey: nlMigrationKey)
        if let rawProvider = persistence.optionalString(forKey: "indexEmbeddingProvider"),
           let provider = IndexEmbeddingProviderID(rawValue: rawProvider) {
            if provider == .deterministic, nlMigrationDone == false {
                self.indexEmbeddingProvider = .appleNL
                persistence.set(IndexEmbeddingProviderID.appleNL, forKey: "indexEmbeddingProvider")
            } else {
                self.indexEmbeddingProvider = provider
            }
        } else {
            self.indexEmbeddingProvider = .appleNL
        }
        persistence.set(true, forKey: nlMigrationKey)
        self.indexOpenAIModel = persistence.string(forKey: "indexOpenAIModel", defaultValue: "text-embedding-3-small")
    }
}
