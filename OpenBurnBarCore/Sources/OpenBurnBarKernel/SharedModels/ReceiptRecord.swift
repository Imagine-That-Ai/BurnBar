import CryptoKit
import Foundation

// MARK: - Receipt Record

/// Represents a durable, itemized receipt for an AI coding session or run.
///
/// Contains token breakdowns, cost calculations, efficiency metrics (cache hit ratio,
/// throughput), file modifications, tool calls, and a SHA-256 provenance signature.
public struct ReceiptRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionId: String
    public let projectName: String
    public let provider: AgentProvider
    public let modelName: String
    public let timestamp: Date
    public let durationSeconds: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalCostUSD: Double
    public let estimatedCacheSavingsUSD: Double
    public let cacheHitPercentage: Double
    public let tokensPerSecond: Double
    public let promptSummary: String
    public let filesTouched: [String]
    public let toolsUsed: [String]
    public let harness: String
    public let actualAccomplishments: [String]
    public var qualityReview: ReceiptQualityReview?
    public let achievements: [ReceiptAchievement]
    public let gitStats: ReceiptGitStats?
    public let gitBranch: String?
    public let gitCommit: String?
    public var isStarred: Bool
    public let contentSignature: String

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        projectName: String,
        provider: AgentProvider,
        modelName: String,
        harness: String = "",
        timestamp: Date = Date(),
        durationSeconds: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        totalCostUSD: Double = 0,
        estimatedCacheSavingsUSD: Double = 0,
        cacheHitPercentage: Double = 0,
        tokensPerSecond: Double = 0,
        promptSummary: String = "",
        actualAccomplishments: [String] = [],
        qualityReview: ReceiptQualityReview? = nil,
        achievements: [ReceiptAchievement] = [],
        gitStats: ReceiptGitStats? = nil,
        filesTouched: [String] = [],
        toolsUsed: [String] = [],
        gitBranch: String? = nil,
        gitCommit: String? = nil,
        isStarred: Bool = false,
        contentSignature: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectName = projectName
        self.provider = provider
        self.modelName = modelName
        self.harness = harness.isEmpty ? provider.displayName : harness
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalCostUSD = totalCostUSD
        self.estimatedCacheSavingsUSD = estimatedCacheSavingsUSD
        self.cacheHitPercentage = cacheHitPercentage
        self.tokensPerSecond = tokensPerSecond
        self.promptSummary = promptSummary
        self.actualAccomplishments = actualAccomplishments
        self.qualityReview = qualityReview
        self.achievements = achievements
        self.gitStats = gitStats
        self.filesTouched = filesTouched
        self.toolsUsed = toolsUsed
        self.gitBranch = gitBranch
        self.gitCommit = gitCommit
        self.isStarred = isStarred

        if let contentSignature, !contentSignature.isEmpty {
            self.contentSignature = contentSignature
        } else {
            self.contentSignature = Self.computeSignature(
                sessionId: sessionId,
                projectName: projectName,
                provider: provider.rawValue,
                modelName: modelName,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalCostUSD: totalCostUSD
            )
        }
    }

    // MARK: - Computed Properties

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public var formattedCost: String {
        if totalCostUSD >= 1.0 {
            return String(format: "$%.2f", totalCostUSD)
        } else if totalCostUSD >= 0.01 {
            return String(format: "$%.2f", totalCostUSD)
        } else if totalCostUSD > 0 {
            return String(format: "$%.4f", totalCostUSD)
        } else {
            return "$0.00"
        }
    }

    public var formattedSavings: String {
        if estimatedCacheSavingsUSD >= 0.01 {
            return String(format: "$%.2f", estimatedCacheSavingsUSD)
        } else if estimatedCacheSavingsUSD > 0 {
            return String(format: "$%.4f", estimatedCacheSavingsUSD)
        } else {
            return "$0.00"
        }
    }

    public var formattedTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000.0)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fk", Double(totalTokens) / 1_000.0)
        } else {
            return "\(totalTokens)"
        }
    }

    public var shortSignature: String {
        String(contentSignature.prefix(8)).uppercased()
    }

    public var formattedDuration: String {
        guard durationSeconds > 0 else { return "<1s" }
        if durationSeconds < 60 {
            return String(format: "%.1fs", durationSeconds)
        }
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return "\(minutes)m \(seconds)s"
    }

    // MARK: - Provenance Signature

    public static func computeSignature(
        sessionId: String,
        projectName: String,
        provider: String,
        modelName: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        totalCostUSD: Double
    ) -> String {
        let payload = "\(sessionId)|\(projectName)|\(provider)|\(modelName)|\(timestamp.timeIntervalSince1970)|\(inputTokens)|\(outputTokens)|\(totalCostUSD)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Supporting Receipt Models

public struct ReceiptGitStats: Codable, Hashable, Sendable {
    public let insertions: Int
    public let deletions: Int
    public let filesChanged: Int
    public let commitsCreated: Int

    public init(
        insertions: Int = 0,
        deletions: Int = 0,
        filesChanged: Int = 0,
        commitsCreated: Int = 0
    ) {
        self.insertions = insertions
        self.deletions = deletions
        self.filesChanged = filesChanged
        self.commitsCreated = commitsCreated
    }

    public var summary: String {
        var parts: [String] = []
        if commitsCreated > 0 {
            parts.append("\(commitsCreated) commit\(commitsCreated == 1 ? "" : "s")")
        }
        if filesChanged > 0 {
            parts.append("\(filesChanged) file\(filesChanged == 1 ? "" : "s")")
        }
        if insertions > 0 || deletions > 0 {
            parts.append("+\(insertions)/-\(deletions)")
        }
        return parts.joined(separator: " • ")
    }
}

public struct ReceiptAchievement: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    public let code: String
    public let title: String
    public let icon: String
    public let detail: String

    public init(code: String, title: String, icon: String, detail: String) {
        self.code = code
        self.title = title
        self.icon = icon
        self.detail = detail
    }

    public static let speedDemon = ReceiptAchievement(
        code: "speed_demon",
        title: "Speed Demon",
        icon: "bolt.fill",
        detail: ">150 tok/s throughput"
    )
    public static let cacheBeast = ReceiptAchievement(
        code: "cache_beast",
        title: "Cache Beast",
        icon: "arrow.triangle.2.circlepath",
        detail: ">80% prompt cache hit ratio"
    )
    public static let testsPassing = ReceiptAchievement(
        code: "tests_passing",
        title: "Green Suite",
        icon: "checkmark.seal.fill",
        detail: "Automated test suite verified passing"
    )
    public static let cleanCommit = ReceiptAchievement(
        code: "clean_commit",
        title: "Committed",
        icon: "arrow.triangle.branch",
        detail: "Changes committed to version control"
    )
    public static let frugal = ReceiptAchievement(
        code: "frugal",
        title: "Frugal",
        icon: "dollarsign.circle",
        detail: "Under $0.05 total spend"
    )
    public static let marathon = ReceiptAchievement(
        code: "marathon",
        title: "Marathon",
        icon: "flame.fill",
        detail: "Over 30m sustained session"
    )

    public static let allPredefined: [ReceiptAchievement] = [
        .speedDemon,
        .cacheBeast,
        .testsPassing,
        .cleanCommit,
        .frugal,
        .marathon
    ]
}

public struct ReceiptQualityReview: Codable, Hashable, Sendable {
    public let grade: String // e.g. "A+", "A", "B", "C", "D"
    public let score: Double // 0.0 - 100.0
    public let goalScore: Double // 0.0 - 100.0
    public let rigorScore: Double // 0.0 - 100.0
    public let efficiencyScore: Double // 0.0 - 100.0
    public let wins: [String]
    public let critiques: [String]
    public let reviewedAt: Date
    public let modelUsed: String?

    public init(
        grade: String,
        score: Double,
        goalScore: Double,
        rigorScore: Double,
        efficiencyScore: Double,
        wins: [String] = [],
        critiques: [String] = [],
        reviewedAt: Date = Date(),
        modelUsed: String? = nil
    ) {
        self.grade = grade
        self.score = score
        self.goalScore = goalScore
        self.rigorScore = rigorScore
        self.efficiencyScore = efficiencyScore
        self.wins = wins
        self.critiques = critiques
        self.reviewedAt = reviewedAt
        self.modelUsed = modelUsed
    }
}

