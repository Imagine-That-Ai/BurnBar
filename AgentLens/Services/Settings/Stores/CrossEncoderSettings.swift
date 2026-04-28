import Foundation

// MARK: - Cross-Encoder Settings

@Observable
@MainActor
final class CrossEncoderSettings {
    private let persistence: SettingsPersistenceCoordinator

    var crossEncoderRerankEnabled: Bool = false {
        didSet { persistence.set(crossEncoderRerankEnabled, forKey: "crossEncoderRerankEnabled") }
    }

    var crossEncoderProvider: CrossEncoderProviderID = .codexCLI {
        didSet { persistence.set(crossEncoderProvider, forKey: "crossEncoderProvider") }
    }

    var crossEncoderModel: String = "" {
        didSet { persistence.set(crossEncoderModel, forKey: "crossEncoderModel") }
    }

    var crossEncoderBaseURL: String = "" {
        didSet { persistence.set(crossEncoderBaseURL, forKey: "crossEncoderBaseURL") }
    }

    var crossEncoderMaxCandidates: Int = 40 {
        didSet { persistence.set(crossEncoderMaxCandidates, forKey: "crossEncoderMaxCandidates") }
    }

    var crossEncoderMaxCharsPerCandidate: Int = 512 {
        didSet { persistence.set(crossEncoderMaxCharsPerCandidate, forKey: "crossEncoderMaxCharsPerCandidate") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "crossEncoderRerankEnabled") {
            self.crossEncoderRerankEnabled = persistence.bool(forKey: "crossEncoderRerankEnabled")
        } else {
            self.crossEncoderRerankEnabled = false
        }
        let loadedProvider = persistence.optionalString(forKey: "crossEncoderProvider")
            .flatMap(CrossEncoderProviderID.init(rawValue:))
            ?? .codexCLI
        self.crossEncoderProvider = loadedProvider
        let loadedModel = persistence.string(forKey: "crossEncoderModel")
            ?? CrossEncoderCatalog.defaultModel(for: loadedProvider)
        self.crossEncoderModel = CrossEncoderCatalog.normalizedModel(
            loadedModel,
            provider: loadedProvider
        )
        self.crossEncoderBaseURL = persistence.string(forKey: "crossEncoderBaseURL")
        if persistence.objectExists(forKey: "crossEncoderMaxCandidates") {
            self.crossEncoderMaxCandidates = max(persistence.integer(forKey: "crossEncoderMaxCandidates"), 5)
        } else {
            self.crossEncoderMaxCandidates = 40
        }
        if persistence.objectExists(forKey: "crossEncoderMaxCharsPerCandidate") {
            self.crossEncoderMaxCharsPerCandidate = max(persistence.integer(forKey: "crossEncoderMaxCharsPerCandidate"), 128)
        } else {
            self.crossEncoderMaxCharsPerCandidate = 512
        }
    }
}
