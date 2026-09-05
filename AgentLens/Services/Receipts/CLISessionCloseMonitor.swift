import Foundation
import Observation
import OpenBurnBarCore
import OpenBurnBarKernel
import UserNotifications

// MARK: - CLI Session Close Monitor

/// Tracks active CLI sessions across external agents (Claude Code, Codex, Grok, etc.)
/// and mints rich receipts with accomplishments and quality reviews when they close.
@Observable
@MainActor
final class CLISessionCloseMonitor {

    struct ActiveCLISession: Sendable {
        let id: String
        let provider: AgentProvider
        let harness: String
        let projectName: String
        let projectPath: String?
        var modelName: String
        let startTime: Date
        var lastActiveAt: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var costUSD: Double
        var promptSummary: String
        var filesTouched: Set<String>
        var toolsUsed: Set<String>
        var lastAssistantMessage: String?
        var gitBranch: String?
        var gitCommit: String?
        var hasExplicitlyEnded: Bool

        init(
            id: String,
            provider: AgentProvider,
            harness: String,
            projectName: String,
            projectPath: String? = nil,
            modelName: String = "unknown",
            startTime: Date = Date(),
            lastActiveAt: Date = Date(),
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            costUSD: Double = 0,
            promptSummary: String = "",
            filesTouched: Set<String> = [],
            toolsUsed: Set<String> = [],
            lastAssistantMessage: String? = nil,
            gitBranch: String? = nil,
            gitCommit: String? = nil,
            hasExplicitlyEnded: Bool = false
        ) {
            self.id = id
            self.provider = provider
            self.harness = harness
            self.projectName = projectName
            self.projectPath = projectPath
            self.modelName = modelName
            self.startTime = startTime
            self.lastActiveAt = lastActiveAt
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.costUSD = costUSD
            self.promptSummary = promptSummary
            self.filesTouched = filesTouched
            self.toolsUsed = toolsUsed
            self.lastAssistantMessage = lastAssistantMessage
            self.gitBranch = gitBranch
            self.gitCommit = gitCommit
            self.hasExplicitlyEnded = hasExplicitlyEnded
        }
    }

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let synthesizer: ReceiptAccomplishmentSynthesizer
    private let auditor: ReceiptQualityAuditor

    private(set) var activeSessions: [String: ActiveCLISession] = [:]
    private var closedSessionIDs: Set<String> = []
    private var checkTask: Task<Void, Never>?
    private let monitorStartedAt: Date = Date()

    /// Quiet period after which an inactive completed turn produces a receipt.
    var quietPeriodSeconds: TimeInterval = 60.0

    /// Callback fired on the main actor whenever a new receipt is finalized.
    var onReceiptPrinted: (@MainActor (ReceiptRecord) -> Void)?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        llmClient: SummaryLLMClient = SummaryLLMClient(),
        onReceiptPrinted: (@MainActor (ReceiptRecord) -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.synthesizer = ReceiptAccomplishmentSynthesizer(llmClient: llmClient)
        self.auditor = ReceiptQualityAuditor(llmClient: llmClient)
        self.onReceiptPrinted = onReceiptPrinted

        startPeriodicCheck()
    }

    // MARK: - Activity Tracking

    func recordActivity(
        conversation: ConversationRecord,
        usages: [TokenUsage] = [],
        hasExplicitEnd: Bool = false
    ) {
        let sid = conversation.sessionId
        guard !closedSessionIDs.contains(sid) else { return }

        let harness = Self.resolveHarnessName(for: conversation.provider)
        let now = Date()

        let totalIn = usages.reduce(0) { $0 + $1.inputTokens }
        let totalOut = usages.reduce(0) { $0 + $1.outputTokens }
        let totalRead = usages.reduce(0) { $0 + $1.cacheReadTokens }
        let totalWrite = usages.reduce(0) { $0 + $1.cacheWriteTokens }
        let totalCost = usages.reduce(0.0) { $0 + $1.costUSD }

        let modelFromUsage = usages.first(where: { !$0.model.isEmpty })?.model
            ?? conversation.summaryModel
            ?? "unknown"

        if var existing = activeSessions[sid] {
            existing.lastActiveAt = now
            existing.inputTokens = max(existing.inputTokens, totalIn)
            existing.outputTokens = max(existing.outputTokens, totalOut)
            existing.cacheReadTokens = max(existing.cacheReadTokens, totalRead)
            existing.cacheWriteTokens = max(existing.cacheWriteTokens, totalWrite)
            existing.costUSD = max(existing.costUSD, totalCost)
            if modelFromUsage != "unknown" { existing.modelName = modelFromUsage }
            if !conversation.inferredTaskTitle.isEmpty { existing.promptSummary = conversation.inferredTaskTitle }
            if !conversation.keyFiles.isEmpty { existing.filesTouched.formUnion(conversation.keyFiles) }
            if !conversation.keyTools.isEmpty { existing.toolsUsed.formUnion(conversation.keyTools) }
            if !conversation.lastAssistantMessage.isEmpty { existing.lastAssistantMessage = conversation.lastAssistantMessage }
            if hasExplicitEnd || conversation.endTime != nil { existing.hasExplicitlyEnded = true }
            activeSessions[sid] = existing
        } else {
            let sessionTime = conversation.fileModifiedAt ?? conversation.startTime ?? now
            activeSessions[sid] = ActiveCLISession(
                id: sid,
                provider: conversation.provider,
                harness: harness,
                projectName: conversation.projectName.isEmpty ? "Default" : conversation.projectName,
                projectPath: conversation.workingDirectory,
                modelName: modelFromUsage,
                startTime: conversation.startTime ?? now,
                lastActiveAt: sessionTime,
                inputTokens: totalIn,
                outputTokens: totalOut,
                cacheReadTokens: totalRead,
                cacheWriteTokens: totalWrite,
                costUSD: totalCost,
                promptSummary: conversation.inferredTaskTitle.isEmpty ? (conversation.summary ?? "") : conversation.inferredTaskTitle,
                filesTouched: Set(conversation.keyFiles),
                toolsUsed: Set(conversation.keyTools),
                lastAssistantMessage: conversation.lastAssistantMessage.isEmpty ? nil : conversation.lastAssistantMessage,
                gitBranch: nil,
                gitCommit: nil,
                hasExplicitlyEnded: hasExplicitEnd || conversation.endTime != nil
            )
        }

        // If explicit termination was flagged, check immediately
        if hasExplicitEnd || conversation.endTime != nil {
            Task { @MainActor [weak self] in
                await self?.checkClosedSessions()
            }
        }
    }

    // MARK: - Periodic & Explicit Close Checks

    private func startPeriodicCheck() {
        checkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // check every 10s
                guard let self else { break }
                await self.checkClosedSessions()
            }
        }
    }

    public func checkClosedSessions(now: Date = Date()) async {
        await ingestRecentSessionsFromDataStore(now: now)

        var sessionsToClose: [ActiveCLISession] = []

        for (sid, session) in activeSessions {
            let elapsedSinceActive = now.timeIntervalSince(session.lastActiveAt)
            let isCandidate = (session.costUSD > 0 || session.inputTokens > 0 || session.outputTokens > 0)

            if session.hasExplicitlyEnded && isCandidate {
                sessionsToClose.append(session)
            } else if elapsedSinceActive >= quietPeriodSeconds && isCandidate {
                sessionsToClose.append(session)
            }
        }

        for session in sessionsToClose {
            activeSessions.removeValue(forKey: session.id)
            closedSessionIDs.insert(session.id)
            await finalizeReceipt(for: session, closedAt: now)
        }
    }

    private func ingestRecentSessionsFromDataStore(now: Date) async {
        guard let recentConvs = try? await dataStore.fetchConversations(limit: 30) else { return }
        let recentUsages = (try? await dataStore.fetchRecentUsage(limit: 150)) ?? []
        let usagesBySession = Dictionary(grouping: recentUsages, by: \.sessionId)

        for conv in recentConvs {
            guard !conv.sessionId.isEmpty else { continue }
            guard !closedSessionIDs.contains(conv.sessionId) else { continue }

            // If a receipt was already persisted for this session, skip minting
            if let _ = try? await dataStore.fetchReceiptForSession(sessionId: conv.sessionId) {
                closedSessionIDs.insert(conv.sessionId)
                continue
            }

            let usages = usagesBySession[conv.sessionId] ?? []
            let isCandidate = !usages.isEmpty || conv.messageCount > 0
            guard isCandidate else { continue }

            recordActivity(
                conversation: conv,
                usages: usages,
                hasExplicitEnd: conv.endTime != nil
            )
        }
    }

    // MARK: - Receipt Finalization

    private func finalizeReceipt(for session: ActiveCLISession, closedAt: Date) async {
        let duration = max(1.0, closedAt.timeIntervalSince(session.startTime))
        let totalTokens = session.inputTokens + session.outputTokens + session.cacheReadTokens + session.cacheWriteTokens
        let cacheHit = totalTokens > 0 ? (Double(session.cacheReadTokens) / Double(totalTokens)) * 100.0 : 0.0
        let speed = duration > 0 ? Double(totalTokens) / duration : 0.0

        let baseInputCost = (Double(session.cacheReadTokens) / 1_000_000.0) * 3.0
        let discountedCost = (Double(session.cacheReadTokens) / 1_000_000.0) * 0.30
        let savings = max(0.0, baseInputCost - discountedCost)

        // 1. Synthesize verified accomplishments & git stats
        let synthesisContext = ReceiptAccomplishmentSynthesizer.SynthesisContext(
            projectName: session.projectName,
            projectPath: session.projectPath,
            promptSummary: session.promptSummary,
            filesTouched: Array(session.filesTouched),
            toolsUsed: Array(session.toolsUsed),
            durationSeconds: duration,
            tokensPerSecond: speed,
            cacheHitPercentage: cacheHit,
            totalCostUSD: session.costUSD,
            lastAssistantMessage: session.lastAssistantMessage
        )

        let synthesis = await synthesizer.synthesize(context: synthesisContext)

        // 2. Build preliminary ReceiptRecord
        var receipt = ReceiptRecord(
            id: "rcpt_\(session.id)",
            sessionId: session.id,
            projectName: session.projectName,
            provider: session.provider,
            modelName: session.modelName,
            harness: session.harness,
            timestamp: closedAt,
            durationSeconds: duration,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            cacheReadTokens: session.cacheReadTokens,
            cacheWriteTokens: session.cacheWriteTokens,
            totalCostUSD: session.costUSD,
            estimatedCacheSavingsUSD: savings,
            cacheHitPercentage: cacheHit,
            tokensPerSecond: speed,
            promptSummary: session.promptSummary,
            actualAccomplishments: synthesis.accomplishments,
            qualityReview: nil,
            achievements: synthesis.achievements,
            gitStats: synthesis.gitStats,
            filesTouched: Array(session.filesTouched),
            toolsUsed: Array(session.toolsUsed),
            gitBranch: session.gitBranch,
            gitCommit: session.gitCommit,
            isStarred: false
        )

        // 3. Optional Quality Review if enabled in settings
        if settingsManager.receiptAutoQualityReviewEnabled {
            let review = await auditor.audit(receipt: receipt)
            receipt = ReceiptRecord(
                id: receipt.id,
                sessionId: receipt.sessionId,
                projectName: receipt.projectName,
                provider: receipt.provider,
                modelName: receipt.modelName,
                harness: receipt.harness,
                timestamp: receipt.timestamp,
                durationSeconds: receipt.durationSeconds,
                inputTokens: receipt.inputTokens,
                outputTokens: receipt.outputTokens,
                cacheReadTokens: receipt.cacheReadTokens,
                cacheWriteTokens: receipt.cacheWriteTokens,
                totalCostUSD: receipt.totalCostUSD,
                estimatedCacheSavingsUSD: receipt.estimatedCacheSavingsUSD,
                cacheHitPercentage: receipt.cacheHitPercentage,
                tokensPerSecond: receipt.tokensPerSecond,
                promptSummary: receipt.promptSummary,
                actualAccomplishments: receipt.actualAccomplishments,
                qualityReview: review,
                achievements: receipt.achievements,
                gitStats: receipt.gitStats,
                filesTouched: receipt.filesTouched,
                toolsUsed: receipt.toolsUsed,
                gitBranch: receipt.gitBranch,
                gitCommit: receipt.gitCommit,
                isStarred: receipt.isStarred,
                contentSignature: receipt.contentSignature
            )
        }

        // 4. Persist to DataStore
        try? await dataStore.insertReceipt(receipt)

        // 5. Play thermal printer tactile audio sound and present notification if live session
        let isLiveSession = session.lastActiveAt.timeIntervalSince(monitorStartedAt) >= -180.0
        if isLiveSession {
            ReceiptAudioPlayer.playReceiptPrintSound(enabled: settingsManager.receiptSoundEnabled)

            // 6. Notify observers (menu bar flyout popover)
            onReceiptPrinted?(receipt)

            // 7. System notification banner if enabled
            if settingsManager.receiptSystemNotificationsEnabled {
                dispatchSystemNotification(for: receipt)
            }
        }
    }

    private func dispatchSystemNotification(for receipt: ReceiptRecord) {
        let content = UNMutableNotificationContent()
        content.title = "🧾 New Receipt: \(receipt.projectName)"
        let accomplishment = receipt.actualAccomplishments.first ?? receipt.promptSummary
        content.body = "\(receipt.formattedCost) • \(receipt.formattedDuration) • \(accomplishment)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "openburnbar.receipt.\(receipt.id)",
            content: content,
            trigger: nil // immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Harness Resolution

    static func resolveHarnessName(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex CLI"
        case .xAI:
            return "Grok CLI"
        case .cursor:
            return "Cursor"
        case .aider:
            return "Aider"
        case .openCode:
            return "OpenCode"
        default:
            return "\(provider.displayName) CLI"
        }
    }
}
