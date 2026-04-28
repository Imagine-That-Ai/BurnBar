import Foundation

// MARK: - Summary Settings

@Observable
@MainActor
final class SummarySettings {
    private let persistence: SettingsPersistenceCoordinator

    var autoSessionSummariesEnabled: Bool = true {
        didSet { persistence.set(autoSessionSummariesEnabled, forKey: "autoSessionSummariesEnabled") }
    }

    var summaryProviderOrderCSV: String = "local,mlx,minimax,openrouter,zai" {
        didSet { persistence.set(summaryProviderOrderCSV, forKey: "summaryProviderOrderCSV") }
    }

    var summaryDailyCapUSD: Double? = nil {
        didSet {
            if let cap = summaryDailyCapUSD {
                persistence.set(true, forKey: "hasSummaryDailyCapUSD")
                persistence.set(cap, forKey: "summaryDailyCapUSD")
            } else {
                persistence.set(false, forKey: "hasSummaryDailyCapUSD")
                persistence.removeObject(forKey: "summaryDailyCapUSD")
            }
        }
    }

    var summaryOpenRouterPrimaryModel: String = "qwen/qwen3.5-9b" {
        didSet { persistence.set(summaryOpenRouterPrimaryModel, forKey: "summaryOpenRouterPrimaryModel") }
    }

    var summaryOpenRouterFallbackModel: String = "openai/gpt-5-nano" {
        didSet { persistence.set(summaryOpenRouterFallbackModel, forKey: "summaryOpenRouterFallbackModel") }
    }

    var summaryMiniMaxModel: String = "gpt-5.5" {
        didSet { persistence.set(summaryMiniMaxModel, forKey: "summaryMiniMaxModel") }
    }

    var summaryZaiModel: String = "glm-5-turbo" {
        didSet { persistence.set(summaryZaiModel, forKey: "summaryZaiModel") }
    }

    var summaryLocalModel: String = "qwen3.5:9b" {
        didSet { persistence.set(summaryLocalModel, forKey: "summaryLocalModel") }
    }

    var summaryLocalBaseURL: String = "http://127.0.0.1:11434" {
        didSet { persistence.set(summaryLocalBaseURL, forKey: "summaryLocalBaseURL") }
    }

    var summaryMLXModel: String = "mlx-community/Qwen3-4B-4bit" {
        didSet { persistence.set(summaryMLXModel, forKey: "summaryMLXModel") }
    }

    var summaryMLXBaseURL: String = "http://127.0.0.1:8080" {
        didSet { persistence.set(summaryMLXBaseURL, forKey: "summaryMLXBaseURL") }
    }

    var summaryMaxPromptChars: Int = 60_000 {
        didSet { persistence.set(summaryMaxPromptChars, forKey: "summaryMaxPromptChars") }
    }

    var summaryMaxOutputTokens: Int = 280 {
        didSet { persistence.set(summaryMaxOutputTokens, forKey: "summaryMaxOutputTokens") }
    }

    var summaryRetryCount: Int = 1 {
        didSet { persistence.set(summaryRetryCount, forKey: "summaryRetryCount") }
    }

    var summaryBatchSize: Int = 25 {
        didSet { persistence.set(summaryBatchSize, forKey: "summaryBatchSize") }
    }

    var summaryFirstLoadBatchSize: Int = 120 {
        didSet { persistence.set(summaryFirstLoadBatchSize, forKey: "summaryFirstLoadBatchSize") }
    }

    var summaryInitialSweepCompleted: Bool = false {
        didSet { persistence.set(summaryInitialSweepCompleted, forKey: "summaryInitialSweepCompleted") }
    }

    var summaryRequestTimeoutSeconds: Double = 20 {
        didSet { persistence.set(summaryRequestTimeoutSeconds, forKey: "summaryRequestTimeoutSeconds") }
    }

    var summaryMaxConcurrency: Int = 8 {
        didSet { persistence.set(summaryMaxConcurrency, forKey: "summaryMaxConcurrency") }
    }

    var summaryTimeLimitMinutes: Int = 0 {
        didSet { persistence.set(summaryTimeLimitMinutes, forKey: "summaryTimeLimitMinutes") }
    }

    var summaryProviderOrder: [SummaryProviderID] {
        let parsed = summaryProviderOrderCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .compactMap(SummaryProviderID.init(rawValue:))
        if parsed.isEmpty {
            return [.local, .mlx, .minimax, .openrouter, .zai]
        }

        var deduped: [SummaryProviderID] = []
        for id in parsed where !deduped.contains(id) {
            deduped.append(id)
        }
        for id in SummaryProviderID.allCases where !deduped.contains(id) {
            deduped.append(id)
        }
        return deduped
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "autoSessionSummariesEnabled") {
            self.autoSessionSummariesEnabled = persistence.bool(forKey: "autoSessionSummariesEnabled")
        } else {
            self.autoSessionSummariesEnabled = true
        }
        self.summaryProviderOrderCSV = persistence.string(forKey: "summaryProviderOrderCSV", defaultValue: "local,mlx,minimax,openrouter,zai")
        if persistence.bool(forKey: "hasSummaryDailyCapUSD") {
            self.summaryDailyCapUSD = persistence.double(forKey: "summaryDailyCapUSD")
        } else {
            self.summaryDailyCapUSD = nil
        }
        self.summaryOpenRouterPrimaryModel = persistence.string(forKey: "summaryOpenRouterPrimaryModel", defaultValue: "qwen/qwen3.5-9b")
        self.summaryOpenRouterFallbackModel = persistence.string(forKey: "summaryOpenRouterFallbackModel", defaultValue: "openai/gpt-5-nano")
        self.summaryMiniMaxModel = persistence.string(forKey: "summaryMiniMaxModel", defaultValue: "gpt-5.5")
        self.summaryZaiModel = persistence.string(forKey: "summaryZaiModel", defaultValue: "glm-5-turbo")
        self.summaryLocalModel = persistence.string(forKey: "summaryLocalModel", defaultValue: "qwen3.5:9b")
        self.summaryLocalBaseURL = persistence.string(forKey: "summaryLocalBaseURL", defaultValue: "http://127.0.0.1:11434")
        self.summaryMLXModel = persistence.string(forKey: "summaryMLXModel", defaultValue: "mlx-community/Qwen3-4B-4bit")
        self.summaryMLXBaseURL = persistence.string(forKey: "summaryMLXBaseURL", defaultValue: "http://127.0.0.1:8080")
        if persistence.objectExists(forKey: "summaryMaxPromptChars") {
            self.summaryMaxPromptChars = max(persistence.integer(forKey: "summaryMaxPromptChars"), 4_000)
        } else {
            self.summaryMaxPromptChars = 60_000
        }
        if persistence.objectExists(forKey: "summaryMaxOutputTokens") {
            self.summaryMaxOutputTokens = max(persistence.integer(forKey: "summaryMaxOutputTokens"), 120)
        } else {
            self.summaryMaxOutputTokens = 280
        }
        if persistence.objectExists(forKey: "summaryRetryCount") {
            self.summaryRetryCount = max(persistence.integer(forKey: "summaryRetryCount"), 0)
        } else {
            self.summaryRetryCount = 1
        }
        if persistence.objectExists(forKey: "summaryBatchSize") {
            self.summaryBatchSize = max(persistence.integer(forKey: "summaryBatchSize"), 1)
        } else {
            self.summaryBatchSize = 25
        }
        if persistence.objectExists(forKey: "summaryFirstLoadBatchSize") {
            self.summaryFirstLoadBatchSize = max(persistence.integer(forKey: "summaryFirstLoadBatchSize"), 1)
        } else {
            self.summaryFirstLoadBatchSize = 120
        }
        self.summaryInitialSweepCompleted = persistence.bool(forKey: "summaryInitialSweepCompleted")
        if persistence.objectExists(forKey: "summaryRequestTimeoutSeconds") {
            let timeoutSeconds = persistence.double(forKey: "summaryRequestTimeoutSeconds")
            self.summaryRequestTimeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 20
        } else {
            self.summaryRequestTimeoutSeconds = 20
        }
        if persistence.objectExists(forKey: "summaryMaxConcurrency") {
            self.summaryMaxConcurrency = max(persistence.integer(forKey: "summaryMaxConcurrency"), 1)
        } else {
            self.summaryMaxConcurrency = 8
        }
        if persistence.objectExists(forKey: "summaryTimeLimitMinutes") {
            self.summaryTimeLimitMinutes = max(persistence.integer(forKey: "summaryTimeLimitMinutes"), 0)
        } else {
            self.summaryTimeLimitMinutes = 0
        }
    }

    func setSummaryProviderOrder(_ order: [SummaryProviderID]) {
        summaryProviderOrderCSV = order.map(\.rawValue).joined(separator: ",")
    }
}
