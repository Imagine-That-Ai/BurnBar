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

    /// Encryption-at-rest is default-ON for new installs (B-DATA-1). Existing
    /// installs keep whatever value they previously persisted (see `init`).
    var databaseEncryptionEnabled: Bool = true {
        didSet { persistence.set(databaseEncryptionEnabled, forKey: "databaseEncryptionEnabled") }
    }

    /// Explicit, persisted, user-acknowledged plaintext escape hatch. When the
    /// build genuinely cannot encrypt (no SQLCipher) or an existing plaintext DB
    /// cannot be safely migrated, the database opens in plaintext only while this
    /// flag is set, and a standing banner should warn the user. Default false:
    /// without it, an encryption failure surfaces rather than silently shipping
    /// plaintext. Persisted under the same key the DB-open path reads from
    /// `UserDefaults.standard` so it is available before `SettingsManager` exists.
    var plaintextDatabaseAcknowledged: Bool = false {
        didSet { persistence.set(plaintextDatabaseAcknowledged, forKey: "plaintextDatabaseAcknowledged") }
    }

    var preferredIndexEmbeddingVersionID: String = "" {
        didSet { persistence.set(preferredIndexEmbeddingVersionID, forKey: "preferredIndexEmbeddingVersionID") }
    }

    var indexEmbeddingProvider: IndexEmbeddingProviderID = .deterministic {
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
        if persistence.objectExists(forKey: "databaseEncryptionEnabled") {
            self.databaseEncryptionEnabled = persistence.bool(forKey: "databaseEncryptionEnabled")
        } else {
            // New install: encryption-at-rest default-on (B-DATA-1).
            self.databaseEncryptionEnabled = true
        }
        self.plaintextDatabaseAcknowledged = persistence.bool(forKey: "plaintextDatabaseAcknowledged")
        self.preferredIndexEmbeddingVersionID = persistence.string(forKey: "preferredIndexEmbeddingVersionID")
        if let rawProvider = persistence.optionalString(forKey: "indexEmbeddingProvider"),
           let provider = IndexEmbeddingProviderID(rawValue: rawProvider) {
            self.indexEmbeddingProvider = provider
        } else {
            self.indexEmbeddingProvider = .deterministic
        }
        self.indexOpenAIModel = persistence.string(forKey: "indexOpenAIModel", defaultValue: "text-embedding-3-small")
    }
}
