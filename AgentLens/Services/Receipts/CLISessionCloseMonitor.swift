import Foundation
import Observation
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
        var projectName: String
        var projectPath: String?
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
        var messageCount: Int

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
            hasExplicitlyEnded: Bool = false,
            messageCount: Int = 0
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
            self.messageCount = messageCount
        }
    }

    /// Newest-N usage is ordered by `startTime`. Codex mints a fresh session
    /// id per run, so those rows stay in the window. Factory / Claude / Grok
    /// reuse one session file for hours; the original start falls out and
    /// the flyout goes silent. Conversations plus a start-time horizon catch
    /// both shapes without scanning `token_usage.endTime`.
    private let ingestHorizonSeconds: TimeInterval = 6 * 60 * 60

    /// Announce only sessions that actually just finished — not the rest of
    /// today's register when the app launches.
    private let liveAnnouncementWindow: TimeInterval = 20 * 60

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let runtimeProbe: any ReceiptCLIRuntimeProbe
    private let synthesizer: ReceiptAccomplishmentSynthesizer
    private let auditor: ReceiptQualityAuditor

    private(set) var activeSessions: [String: ActiveCLISession] = [:]
    /// Slip is already in the register. Quiet time is enough to mint;
    /// announcing waits for the CLI / terminal / app to actually close.
    private var mintedSessionIDs: Set<String> = []
    /// Flyout / sound / notification already fired.
    private var announcedSessionIDs: Set<String> = []
    /// Minted while the runtime was still open — keep probing until it dies,
    /// even after the 20-minute live window. Do not replay historical slips.
    private var pendingAnnounceSessionIDs: Set<String> = []
    /// Historical or already-handled. Skip ingest so a 6-hour scan does not
    /// keep resurrecting yesterday's register.
    private var retiredSessionIDs: Set<String> = []
    /// First-minted while we cannot see this harness's process. Quiet is
    /// not a close — wait for a real conversation end, not the next tick.
    private var awaitingExplicitEndSessionIDs: Set<String> = []
    private var checkTask: Task<Void, Never>?
    private let monitorStartedAt = Date()

    /// Quiet period after which an inactive completed turn produces a receipt.
    var quietPeriodSeconds: TimeInterval = 60.0

    /// Callback fired on the main actor whenever a new receipt is finalized.
    var onReceiptPrinted: (@MainActor (ReceiptRecord) -> Void)?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        llmClient: SummaryLLMClient = SummaryLLMClient(),
        runtimeProbe: (any ReceiptCLIRuntimeProbe)? = nil,
        onReceiptPrinted: (@MainActor (ReceiptRecord) -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.runtimeProbe = runtimeProbe ?? ProcessReceiptCLIRuntimeProbe()
        self.synthesizer = ReceiptAccomplishmentSynthesizer(llmClient: llmClient)
        self.auditor = ReceiptQualityAuditor(llmClient: llmClient)
        self.onReceiptPrinted = onReceiptPrinted

        // Tests drive `checkClosedSessions` directly. The 10s loop would
        // leak one task per monitor (the harness matrix constructs many).
        if !OpenBurnBarRuntime.isRunningTests {
            startPeriodicCheck()
        }
    }

    // MARK: - Activity Tracking

    func recordActivity(
        conversation: ConversationRecord,
        usages: [TokenUsage] = [],
        hasExplicitEnd: Bool = false
    ) {
        let sid = Self.canonicalSessionID(usages: usages, conversation: conversation)
        guard !sid.isEmpty, !announcedSessionIDs.contains(sid), !retiredSessionIDs.contains(sid) else { return }

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
            existing.messageCount = max(existing.messageCount, conversation.messageCount)
            if hasExplicitEnd || Self.conversationHasRealEnd(conversation) { existing.hasExplicitlyEnded = true }
            if let activity = Self.conversationActivityDate(conversation), activity > existing.lastActiveAt {
                existing.lastActiveAt = activity
            }
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
                hasExplicitlyEnded: hasExplicitEnd || Self.conversationHasRealEnd(conversation),
                messageCount: conversation.messageCount
            )
        }

        // If explicit termination was flagged, check immediately
        if hasExplicitEnd || Self.conversationHasRealEnd(conversation) {
            Task { @MainActor [weak self] in
                await self?.checkClosedSessions()
            }
        }
    }

    // MARK: - Periodic & Explicit Close Checks

    private func startPeriodicCheck() {
        checkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // try?-ok(cancellation only; interval between checks)
                guard let self else { break }
                await self.checkClosedSessions()
            }
        }
    }

    private var checkInFlight = false

    func checkClosedSessions(now: Date = Date()) async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        await ingestRecentSessionsFromDataStore(now: now)

        for (sid, session) in activeSessions {
            let elapsedSinceActive = now.timeIntervalSince(session.lastActiveAt)
            let isCandidate = session.costUSD > 0
                || session.inputTokens > 0
                || session.outputTokens > 0
                || session.messageCount > 0
            let shouldMint = isCandidate
                && (session.hasExplicitlyEnded || elapsedSinceActive >= quietPeriodSeconds)

            if shouldMint {
                await mintAndMaybeAnnounce(session, closedAt: now)
            }

            if announcedSessionIDs.contains(sid) || retiredSessionIDs.contains(sid) {
                activeSessions.removeValue(forKey: sid)
                pendingAnnounceSessionIDs.remove(sid)
                awaitingExplicitEndSessionIDs.remove(sid)
            }
        }
    }

    private func ingestRecentSessionsFromDataStore(now: Date) async {
        let horizon = now.addingTimeInterval(-ingestHorizonSeconds)
        let recentByStart = (try? await dataStore.fetchUsage( // try?-ok(ingest skip if usage scan fails)
            startingIn: horizon..<now.addingTimeInterval(60),
            limit: 400
        )) ?? []

        let recentConversations = (try? await dataStore.fetchConversationsWithoutTranscripts( // try?-ok(ingest skip if conversation scan fails)
            limit: 400,
            activeSince: horizon
        )) ?? []

        var conversationByKey: [String: ConversationRecord] = [:]
        var conversationKeys: [String] = []
        for conversation in recentConversations {
            if let activity = Self.conversationActivityDate(conversation), activity < horizon {
                continue
            }
            if !conversation.sessionId.isEmpty {
                conversationByKey[conversation.sessionId] = conversation
                conversationKeys.append(conversation.sessionId)
            }
            conversationByKey[conversation.id] = conversation
            conversationKeys.append(conversation.id)
        }

        let usageForConversations: [TokenUsage]
        if conversationKeys.isEmpty {
            usageForConversations = []
        } else {
            usageForConversations = (try? await dataStore.fetchUsage( // try?-ok(ingest skip if usage join fails)
                sessionIDs: conversationKeys,
                limit: 800
            )) ?? []
        }

        var seenUsageIDs = Set<UUID>()
        var usagesBySession: [String: [TokenUsage]] = [:]
        for usage in recentByStart + usageForConversations {
            guard seenUsageIDs.insert(usage.id).inserted else { continue }
            guard !usage.sessionId.isEmpty else { continue }
            usagesBySession[usage.sessionId, default: []].append(usage)
        }

        let receiptKeys = Array(usagesBySession.keys) + conversationKeys
        let alreadyPrinted = (try? await dataStore.fetchReceiptSessionIDs(among: receiptKeys)) ?? [] // try?-ok(treat unknown rows as unprinted)
        for printed in alreadyPrinted {
            mintedSessionIDs.insert(printed)
        }

        for (sessionId, usages) in usagesBySession {
            guard !announcedSessionIDs.contains(sessionId), !retiredSessionIDs.contains(sessionId) else { continue }
            recordActivity(
                usages: usages,
                conversation: conversationByKey[sessionId]
            )
        }

        for conversation in recentConversations {
            let key = Self.canonicalSessionID(conversation: conversation)
            guard !key.isEmpty else { continue }
            guard usagesBySession[key] == nil, usagesBySession[conversation.id] == nil else { continue }
            guard !announcedSessionIDs.contains(key), !announcedSessionIDs.contains(conversation.id) else { continue }
            guard !retiredSessionIDs.contains(key), !retiredSessionIDs.contains(conversation.id) else { continue }
            recordActivity(usages: [], conversation: conversation)
        }
    }

    private func recordActivity(usages: [TokenUsage], conversation: ConversationRecord?) {
        let seed = usages.max(by: { $0.endTime < $1.endTime })
        guard seed != nil || conversation != nil else { return }

        let sid = Self.canonicalSessionID(usages: usages, conversation: conversation)
        guard !sid.isEmpty, !announcedSessionIDs.contains(sid), !retiredSessionIDs.contains(sid) else { return }

        let provider = seed?.provider ?? conversation?.provider ?? .claudeCode
        let harness = Self.resolveHarnessName(for: provider)
        let totalIn = usages.reduce(0) { $0 + $1.inputTokens }
        let totalOut = usages.reduce(0) { $0 + $1.outputTokens }
        let totalRead = usages.reduce(0) { $0 + $1.cacheReadTokens }
        let totalWrite = usages.reduce(0) { $0 + $1.cacheWriteTokens }
        let totalCost = usages.reduce(0.0) { $0 + $1.costUSD }
        let modelFromUsage = usages.first(where: { !$0.model.isEmpty })?.model
            ?? conversation?.summaryModel
            ?? "unknown"
        let start = usages.map(\.startTime).min()
            ?? conversation?.startTime
            ?? seed?.startTime
            ?? Date()
        let activityFromUsage = seed?.endTime
        let activityFromConversation = conversation.flatMap(Self.conversationActivityDate)
        let lastActive = [activityFromUsage, activityFromConversation].compactMap { $0 }.max() ?? start

        if var existing = activeSessions[sid] {
            // Advance activity only when a newer persisted row or file mtime
            // appeared. Re-reading the same usage set must not reset the
            // quiet-period clock.
            if lastActive > existing.lastActiveAt {
                existing.lastActiveAt = lastActive
            }
            existing.inputTokens = max(existing.inputTokens, totalIn)
            existing.outputTokens = max(existing.outputTokens, totalOut)
            existing.cacheReadTokens = max(existing.cacheReadTokens, totalRead)
            existing.cacheWriteTokens = max(existing.cacheWriteTokens, totalWrite)
            existing.costUSD = max(existing.costUSD, totalCost)
            if modelFromUsage != "unknown" { existing.modelName = modelFromUsage }
            if let conversation { mergeConversationEvidence(into: &existing, conversation: conversation) }
            activeSessions[sid] = existing
        } else {
            activeSessions[sid] = ActiveCLISession(
                id: sid,
                provider: provider,
                harness: harness,
                projectName: Self.ingestedProjectName(seed: seed, conversation: conversation),
                projectPath: conversation?.workingDirectory,
                modelName: modelFromUsage,
                startTime: start,
                lastActiveAt: lastActive,
                inputTokens: totalIn,
                outputTokens: totalOut,
                cacheReadTokens: totalRead,
                cacheWriteTokens: totalWrite,
                costUSD: totalCost,
                promptSummary: Self.ingestedPromptSummary(conversation: conversation),
                filesTouched: Set(conversation?.keyFiles ?? []),
                toolsUsed: Set(conversation?.keyTools ?? []),
                lastAssistantMessage: nil,
                gitBranch: nil,
                gitCommit: nil,
                hasExplicitlyEnded: conversation.map(Self.conversationHasRealEnd) ?? false,
                messageCount: conversation?.messageCount ?? 0
            )
        }
    }

    /// Fills receipt evidence from a metadata-only conversation record. The
    /// lightweight projection omits `lastAssistantMessage` / `fullText`, so
    /// those stay unset here; the conversation-event path still supplies them
    /// whenever transcripts are actually read.
    private func mergeConversationEvidence(
        into session: inout ActiveCLISession,
        conversation: ConversationRecord
    ) {
        let incoming = Self.ingestedPromptSummary(conversation: conversation)
        if !incoming.isEmpty {
            session.promptSummary = incoming
        }
        if !conversation.keyFiles.isEmpty { session.filesTouched.formUnion(conversation.keyFiles) }
        if !conversation.keyTools.isEmpty { session.toolsUsed.formUnion(conversation.keyTools) }
        if session.projectPath == nil, let directory = conversation.workingDirectory {
            session.projectPath = directory
        }
        if session.projectName == "Default", !conversation.projectName.isEmpty {
            session.projectName = conversation.projectName
        }
        session.messageCount = max(session.messageCount, conversation.messageCount)
        if Self.conversationHasRealEnd(conversation) { session.hasExplicitlyEnded = true }
        if let activity = Self.conversationActivityDate(conversation), activity > session.lastActiveAt {
            session.lastActiveAt = activity
        }
    }

    private static func ingestedProjectName(seed: TokenUsage?, conversation: ConversationRecord?) -> String {
        if let seed, !seed.projectName.isEmpty { return seed.projectName }
        if let conversation, !conversation.projectName.isEmpty { return conversation.projectName }
        return "Default"
    }

    private static func canonicalSessionID(
        usages: [TokenUsage] = [],
        conversation: ConversationRecord?
    ) -> String {
        if let conversation {
            let sid = conversation.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sid.isEmpty { return sid }
            return conversation.id
        }
        return usages.first?.sessionId ?? ""
    }

    /// File mtime / last turn — not `indexedAt`, which the parsers stamp
    /// with `Date()` on every rescan and would never go quiet.
    private static func conversationActivityDate(_ conversation: ConversationRecord) -> Date? {
        [conversation.fileModifiedAt, conversation.endTime, conversation.startTime]
            .compactMap { $0 }
            .max()
    }

    /// Factory/Claude parsers often set `endTime = startTime` when the JSONL
    /// has no close event. That is a placeholder, not an explicit end.
    nonisolated static func conversationHasRealEnd(_ conversation: ConversationRecord) -> Bool {
        guard let end = conversation.endTime else { return false }
        guard let start = conversation.startTime else { return true }
        return end.timeIntervalSince(start) > 2
    }

    private static func ingestedPromptSummary(conversation: ConversationRecord?) -> String {
        guard let conversation else { return "" }
        let overlay = ReceiptConversationOverlay(
            conversationID: conversation.id,
            sessionID: conversation.sessionId,
            inferredTaskTitle: conversation.inferredTaskTitle,
            summary: conversation.summary,
            summaryTitle: conversation.summaryTitle,
            workingDirectory: conversation.workingDirectory,
            messageCount: conversation.messageCount,
            keyFiles: conversation.keyFiles
        )
        let stub = ReceiptRecord(
            sessionId: conversation.sessionId,
            projectName: conversation.projectName,
            provider: conversation.provider,
            modelName: conversation.summaryModel ?? ""
        )
        return ReceiptChatBridge.contentSummary(receipt: stub, overlay: overlay)
    }

    // MARK: - Receipt Finalization

    private func mintAndMaybeAnnounce(_ session: ActiveCLISession, closedAt: Date) async {
        let preexisting = mintedSessionIDs.contains(session.id)
        let receipt: ReceiptRecord?
        if preexisting {
            receipt = try? await dataStore.fetchReceiptForSession(sessionId: session.id) // try?-ok(preexisting slip missing is not announce)
        } else if let persisted = await persistReceipt(for: session, closedAt: closedAt) {
            mintedSessionIDs.insert(session.id)
            receipt = persisted
        } else {
            receipt = nil
        }

        let runtimeOpen = await runtimeProbe.isSessionRuntimeOpen(
            provider: session.provider,
            projectPath: session.projectPath
        )
        let live = isWithinLiveAnnouncementWindow(session, now: closedAt)
        let alreadyWaiting = pendingAnnounceSessionIDs.contains(session.id)

        // Open CLI / terminal / app: the slip may print, but announce
        // waits for close. A 25-minute think (first mint or relaunch)
        // must not be retired by the 20-minute live window.
        if runtimeOpen {
            pendingAnnounceSessionIDs.insert(session.id)
            return
        }

        if alreadyWaiting {
            guard let receipt else { return }
            pendingAnnounceSessionIDs.remove(session.id)
            await announce(receipt, session: session)
            return
        }

        let canObserve = AgentCLIProcessClassifier.canObserveRuntime(for: session.provider)
        if awaitingExplicitEndSessionIDs.contains(session.id) {
            guard session.hasExplicitlyEnded, let receipt else { return }
            awaitingExplicitEndSessionIDs.remove(session.id)
            await announce(receipt, session: session)
            return
        }

        if preexisting {
            // Launch replay: already in the register, CLI already gone.
            retiredSessionIDs.insert(session.id)
            return
        }

        // First mint of a never-printed row whose CLI looks gone.
        // If we cannot observe this harness at all, quiet time is not a
        // close — hold for a real conversation end. Do not pending:
        // pending + always-false open announces on the next tick.
        if !canObserve && !session.hasExplicitlyEnded {
            awaitingExplicitEndSessionIDs.insert(session.id)
            return
        }

        // The live window blocks yesterday's register, not a later close.
        guard live else {
            retiredSessionIDs.insert(session.id)
            return
        }
        guard let receipt else { return }
        await announce(receipt, session: session)
    }

    private func persistReceipt(for session: ActiveCLISession, closedAt: Date) async -> ReceiptRecord? {
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

        // 4. Persist to DataStore before any flyout / notification.
        do {
            try await dataStore.insertReceipt(receipt)
            return receipt
        } catch {
            AppLogger.dataStore.error("Failed to persist receipt: \(error)")
            return try? await dataStore.fetchReceiptForSession(sessionId: session.id) // try?-ok(reuse already-printed slip after insert race)
        }
    }

    private func announce(_ receipt: ReceiptRecord, session: ActiveCLISession) async {
        guard !announcedSessionIDs.contains(session.id) else { return }
        announcedSessionIDs.insert(session.id)
        retiredSessionIDs.insert(session.id)

        ReceiptAudioPlayer.playReceiptPrintSound(enabled: settingsManager.receiptSoundEnabled)
        onReceiptPrinted?(receipt)

        if settingsManager.receiptSystemNotificationsEnabled {
            dispatchSystemNotification(for: receipt)
        }
    }

    private func dispatchSystemNotification(for receipt: ReceiptRecord) {
        guard !OpenBurnBarRuntime.isRunningTests else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            switch status {
            case .denied:
                return
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false // try?-ok(optional permission prompt)
                guard granted else { return }
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                return
            }

            let content = UNMutableNotificationContent()
            let copy = ReceiptNotificationRouter.bannerCopy(for: receipt)
            content.title = copy.title
            content.body = copy.body
            // The thermal-printer sample is the product sound. A second
            // system ping on the same close is noise, not confirmation.
            content.sound = nil
            content.categoryIdentifier = ReceiptNotificationRouter.categoryID
            content.userInfo = ReceiptNotificationRouter.userInfo(for: receipt)

            let request = UNNotificationRequest(
                identifier: "openburnbar.receipt.\(receipt.id)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    /// Launch-replay guard: only *start* caring about a session whose last
    /// activity is recent and after (or shortly before) the monitor started.
    /// Once a slip is pending announce, the runtime probe is the gate —
    /// a 25-minute Codex think must still notify when the terminal closes.
    private func isWithinLiveAnnouncementWindow(_ session: ActiveCLISession, now: Date) -> Bool {
        let last = session.lastActiveAt
        guard now.timeIntervalSince(last) <= liveAnnouncementWindow else { return false }
        return last.timeIntervalSince(monitorStartedAt) >= -180
    }

    // MARK: - Harness Resolution

    nonisolated static func resolveHarnessName(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex CLI"
        case .factory:
            return "Factory CLI"
        case .xAI:
            return "Grok CLI"
        case .cursor, .cursorAgent:
            return "Cursor"
        case .aider:
            return "Aider"
        case .openCode:
            return "OpenCode"
        case .hermes:
            return "Hermes"
        case .kimi:
            return "Kimi CLI"
        case .minimax:
            return "MiniMax CLI"
        case .piAgent:
            return "Pi"
        case .geminiCLI:
            return "Gemini CLI"
        case .goose:
            return "Goose"
        case .antigravity:
            return "Antigravity"
        case .muse:
            return "Muse"
        case .openClaude:
            return "OpenClaude"
        case .primeAgent:
            return "Prime Agent"
        case .junie:
            return "Junie"
        case .ollama:
            return "Ollama"
        case .forgeDev:
            return "Forge"
        case .omp:
            return "OMP"
        case .openClaw:
            return "OpenClaw"
        case .zai:
            return "Z.ai"
        case .kiloCode:
            return "Kilo Code"
        case .rooCode:
            return "Roo Code"
        case .copilot:
            return "Copilot"
        case .cline:
            return "Cline"
        case .augment:
            return "Augment"
        case .fx:
            return "fx"
        case .warp:
            return "Warp"
        default:
            let name = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "CLI" }
            if name.range(of: "CLI", options: .caseInsensitive) != nil {
                return name
            }
            return "\(name) CLI"
        }
    }
}
