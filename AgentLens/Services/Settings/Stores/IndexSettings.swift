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

    var databaseEncryptionEnabled: Bool = false {
        didSet { persistence.set(databaseEncryptionEnabled, forKey: "databaseEncryptionEnabled") }
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
            self.databaseEncryptionEnabled = false
        }
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
