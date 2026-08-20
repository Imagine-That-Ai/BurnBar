import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

// Retrieval and local index oracle.
// Extracted from ChatSessionController.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ChatSessionController {

    func hermesHealthReachable() async -> Bool {
        guard var components = URLComponents(url: hermesGatewayBaseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.path = "/health"
        components.query = nil
        guard let url = components.url else { return false }

        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = hermesBearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    func cancelGeneration() {
        streamTask?.cancel()
        Analytics.shared.track(.chatGenerationCancelled, [
            "backend": .string(chatBackend.rawValue)
        ])
        cliBridge.cancel()
        isStreaming = false
        activeStreamMessageId = nil
    }

    func saveUsageIfNeeded(
        _ usageSnapshot: CLIUsageSnapshot?,
        backend: ChatBackendID,
        requestModel: String,
        responseMessageID: String,
        startedAt: Date,
        endedAt: Date
    ) async {
        guard let usageSnapshot else { return }

        let (provider, projectLabel, model): (AgentProvider, String, String) = {
            switch backend {
            case .hermes:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? hermesModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "hermes"
                return (.hermes, "OpenBurnBar Hermes Chat", m)
            case .openclaw:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "unselected"
                return (.openClaw, "OpenBurnBar OpenClaw Chat", m)
            case .piAgent:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? piAgentModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "pi"
                return (.piAgent, "OpenBurnBar Pi Agent Chat", m)
            case .codex:
                let m = chatModelCodex.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "codex"
                return (.codex, "OpenBurnBar Codex Chat", m)
            case .claude:
                let m = chatModelClaude.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "claude"
                return (.claudeCode, "OpenBurnBar Claude Chat", m)
            case .droid:
                let m = chatModelDroid.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "droid"
                return (.factory, "OpenBurnBar Droid Chat", m)
            case .forge:
                let m = chatModelForge.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "forge"
                return (.forgeDev, "OpenBurnBar Forge Chat", m)
            case .antigravity:
                let m = chatModelAntigravity.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "antigravity"
                return (.antigravity, "OpenBurnBar Antigravity Chat", m)
            case .cursorAgent:
                let m = chatModelCursorAgent.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "cursor-agent"
                return (.cursorAgent, "OpenBurnBar Cursor Agent Chat", m)
            case .openClaude:
                let m = chatModelOpenClaude.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "openclaude"
                return (.openClaude, "OpenBurnBar OpenClaude Chat", m)
            case .omp:
                let m = chatModelOMP.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "omp"
                return (.omp, "OpenBurnBar OMP Chat", m)
            case .junie:
                let m = chatModelJunie.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "junie"
                return (.junie, "OpenBurnBar Junie Chat", m)
            case .fx:
                let m = chatModelFx.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "fx"
                return (.fx, "OpenBurnBar fx Chat", m)
            // The provider spelling for Grok is `.xAI`; `AgentProvider` has no `.grok`
            // member, and Kimi has its own `.kimi` rather than being filed under Grok.
            case .grok:
                return (.xAI, "OpenBurnBar Grok Chat", "grok")
            case .kimi:
                return (.kimi, "OpenBurnBar Kimi Chat", "kimi")
            }
        }()

        let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
        let cost: Double
        do {
            cost = try pricing.cost(
                inputTokens: usageSnapshot.inputTokens,
                outputTokens: usageSnapshot.outputTokens,
                cacheCreationTokens: usageSnapshot.cacheCreationTokens,
                cacheReadTokens: usageSnapshot.cacheReadTokens,
                reasoningTokens: usageSnapshot.reasoningTokens
            )
        } catch {
            AppLogger.chat.silentFailure("price in-app chat usage", error: error)
            return
        }
        let usage = TokenUsage(
            provider: provider,
            sessionId: "\(activeThreadID)/\(responseMessageID)",
            projectName: projectLabel,
            model: model,
            inputTokens: usageSnapshot.inputTokens,
            outputTokens: usageSnapshot.outputTokens,
            cacheCreationTokens: usageSnapshot.cacheCreationTokens,
            cacheReadTokens: usageSnapshot.cacheReadTokens,
            reasoningTokens: usageSnapshot.reasoningTokens,
            costUSD: cost,
            startTime: startedAt,
            endTime: endedAt,
            usageSource: .inAppChat,
            provenanceMethod: .inAppChat,
            provenanceConfidence: .exact
        )

        do {
            try await dataStore.insert(usage)
            await dataStore.reloadUsagesIfChanged()
        } catch {
            AppLogger.chat.silentFailure("insert in-app chat usage", error: error)
        }
    }

    func buildConversationJumpTargets(
        queryText: String,
        queryRun: OpenBurnBarQueryRunResult,
        retrievalResults: [RetrievalResult],
        desiredCount: Int
    ) async -> [ConversationJumpTarget] {
        var targets: [ConversationJumpTarget] = []

        let inferredRange = BurnBarSearchTimeWindow.inferredDateRange(
            from: queryText,
            now: Date(),
            calendar: .current
        )
        let exactPatterns = exactJumpPatterns(queryText: queryText, queryRun: queryRun)

        if exactPatterns.isEmpty == false {
            targets = (try? await dataStore.findConversationFullTextMatches(
                patterns: exactPatterns,
                dateRange: inferredRange,
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? []
        }

        if targets.isEmpty {
            targets = retrievalResults.compactMap { result in
                guard let conversation = result.conversation else { return nil }
                return ConversationJumpTarget(
                    conversation: conversation,
                    snippet: result.snippet
                        .replacingOccurrences(of: "<b>", with: "")
                        .replacingOccurrences(of: "</b>", with: ""),
                    startOffset: result.startOffset,
                    endOffset: result.endOffset,
                    source: .retrieval
                )
            }
        }

        var seen = Set<String>()
        return Array(targets.filter { seen.insert($0.id).inserted }.prefix(desiredCount))
    }

    func buildLocalIndexOracleResponse(
        queryText: String,
        queryRun: OpenBurnBarQueryRunResult,
        retrievalResults: [RetrievalResult],
        jumpTargets: [ConversationJumpTarget],
        desiredCount: Int
    ) async -> LocalIndexOracleResult {
        var lines: [String] = []
        let inferredRange = BurnBarSearchTimeWindow.inferredDateRange(
            from: queryText,
            now: Date(),
            calendar: .current
        )
        let canonicalJumpTargets = Array(jumpTargets.prefix(desiredCount))

        if queryRun.plan.analysisIntent == .providerRanking,
           queryRun.plan.aggregatePatterns.isEmpty == false {
            let rankedProviders = (try? await dataStore.countOccurrencesInConversationFullTextByProvider(
                patterns: queryRun.plan.aggregatePatterns,
                dateRange: inferredRange,
                conversationSources: [.providerLog]
            )) ?? []
            let nonZeroProviders = rankedProviders.filter { $0.occurrenceCount > 0 }

            guard let topProvider = nonZeroProviders.first else {
                lines.append("I couldn’t find any indexed strong-language matches grouped by provider for that request.")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
            }

            let providerTargets = (try? await dataStore.findConversationFullTextMatches(
                patterns: queryRun.plan.aggregatePatterns,
                provider: topProvider.provider,
                dateRange: inferredRange,
                conversationSources: [.providerLog],
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? canonicalJumpTargets.filter { $0.conversation.provider == topProvider.provider }

            let displayTargets = Array(providerTargets.prefix(desiredCount))
            lines.append(
                "Indexed answer: across indexed provider sessions, \(topProvider.provider.displayName) has the highest strong-language count."
            )
            lines.append(
                "\(topProvider.provider.displayName): \(topProvider.occurrenceCount) matches across \(topProvider.conversationCount) \(topProvider.conversationCount == 1 ? "session" : "sessions")."
            )
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }

            let rankedDisplayCount = max(1, min(queryRun.plan.requestedResultCount ?? 3, 5))
            let rankingLines = nonZeroProviders.prefix(rankedDisplayCount).enumerated().map { index, entry in
                "\(index + 1). \(entry.provider.displayName) — \(entry.occurrenceCount) matches across \(entry.conversationCount) sessions"
            }
            if rankingLines.isEmpty == false {
                lines.append(rankingLines.joined(separator: "\n"))
            }
            if displayTargets.isEmpty == false {
                lines.append("Matched-session buttons below jump into the top-ranked provider’s sessions.")
                appendJumpTargetSummary(displayTargets, into: &lines)
            }
            return LocalIndexOracleResult(
                message: lines.joined(separator: "\n\n"),
                jumpTargets: displayTargets
            )
        }

        if SearchService.looksLikeSensitiveExactLookup(queryText),
           looksLikeCredentialExposureQuestion(queryText) {
            let scan = (try? await dataStore.scanConversationFullTextForCredentialExposure(
                dateRange: inferredRange,
                limit: exactMatchScanLimit(for: desiredCount)
            )) ?? CredentialExposureScanResult(totalMatches: 0, jumpTargets: [])
            let displayTargets = Array(scan.jumpTargets.prefix(desiredCount))

            if scan.totalMatches > 0 {
                lines.append("Indexed answer: \(scan.totalMatches) likely credential exposure\(scan.totalMatches == 1 ? "" : "s").")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                lines.append("Use the matched-session buttons below to jump to the exact snippets.")
                appendJumpTargetSummary(displayTargets, into: &lines)
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: displayTargets)
            }

            let mentionCount = (try? await dataStore.countOccurrencesInConversationFullText(
                patterns: ["api key", "api_key", "apikey"],
                dateRange: inferredRange
            )) ?? 0

            if mentionCount > 0 {
                lines.append("I found indexed mentions of API keys, but no confident evidence of an actual key value being pasted in the indexed transcripts for that window.")
                lines.append("Mentions found: \(mentionCount).")
                if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                    lines.append(window)
                }
                lines.append("This means the transcripts talk about API keys, but the index did not detect credential-shaped values.")
                return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
            }

            lines.append("I couldn’t find indexed evidence of a credential-like string being pasted in that window.")
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }
            lines.append("If you want, try a narrower project or a more specific provider key name.")
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
        }

        if let count = queryRun.aggregateOccurrenceCount {
            lines.append("Indexed answer: \(count).")
            if queryRun.plan.aggregatePatterns.isEmpty == false {
                lines.append("Patterns counted: \(queryRun.plan.aggregatePatterns.joined(separator: ", ")).")
            }
            if let window = queryRun.aggregateWindowDescription, window.isEmpty == false {
                lines.append(window)
            }
            if canonicalJumpTargets.isEmpty == false {
                lines.append("Use the matched-session buttons below to jump to exact transcript locations.")
                appendJumpTargetSummary(canonicalJumpTargets, into: &lines)
            }
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: canonicalJumpTargets)
        }

        if canonicalJumpTargets.isEmpty == false {
            lines.append("I found indexed matches for that request.")
            lines.append("Use the matched-session buttons below to jump to the exact spot.")
            appendJumpTargetSummary(canonicalJumpTargets, into: &lines)
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: canonicalJumpTargets)
        }

        if retrievalResults.isEmpty == false {
            lines.append("I found relevant indexed sessions, but not a stronger exact transcript match.")
            let topResults = retrievalResults.prefix(desiredCount).map { result in
                let when = (result.conversation?.endTime ?? result.conversation?.startTime ?? result.indexedAt)
                    .formatted(date: .abbreviated, time: .shortened)
                let snippet = result.snippet
                    .replacingOccurrences(of: "<b>", with: "")
                    .replacingOccurrences(of: "</b>", with: "")
                return "- \(result.title) (\(when))\n\(snippet)"
            }
            lines.append(topResults.joined(separator: "\n\n"))
            return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
        }

        lines.append("I couldn’t find a confident match in the indexed conversations, skills, or agent docs on this Mac.")
        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            lines.append("I also did not find an indexed exact match for the credential-related terms in your query.")
        }
        lines.append("Try a quoted phrase, a narrower time window, or a more specific project name.")
        return LocalIndexOracleResult(message: lines.joined(separator: "\n\n"), jumpTargets: [])
    }

    func appendJumpTargetSummary(
        _ jumpTargets: [ConversationJumpTarget],
        into lines: inout [String]
    ) {
        let summary: String = jumpTargets.map { target -> String in
            let when = target.displayTimestamp.formatted(date: .abbreviated, time: .shortened)
            return "- \(target.conversation.inferredTaskTitle) (\(when))\n\(target.snippet)"
        }.joined(separator: "\n\n")
        if summary.isEmpty == false {
            lines.append(summary)
        }
    }

    func exactJumpPatterns(queryText: String, queryRun: OpenBurnBarQueryRunResult) -> [String] {
        if queryRun.plan.aggregatePatterns.isEmpty == false {
            return queryRun.plan.aggregatePatterns
        }

        var patterns: [String] = BurnBarFTSQueryBuilder
            .extractTokens(from: queryText)
            .filter(\.isQuotedPhrase)
            .map { $0.text.lowercased() }

        let lower = queryText.lowercased()
        if lower.contains("api key") {
            patterns.append("api key")
        }
        if lower.contains("api_key") {
            patterns.append("api_key")
        }
        if lower.contains("apikey") {
            patterns.append("apikey")
        }
        if lower.contains("thank you") {
            patterns.append("thank you")
        }

        if patterns.isEmpty,
           Self.looksLikeConversationMemoryQuestion(queryText, plan: queryRun.plan) {
            let informativeTokens = BurnBarFTSQueryBuilder.extractTokens(from: queryText)
                .map(\.text)
                .map { $0.lowercased() }
                .filter { token in
                    token.count >= 3
                        && Self.indexOracleNoiseWords.contains(token) == false
                        && BurnBarFTSQueryBuilder.englishStopwords.contains(token) == false
                }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs < rhs
                }
            var seen = Set<String>()
            patterns.append(
                contentsOf: informativeTokens.filter { seen.insert($0).inserted }.prefix(4)
            )
        }

        return Array(Set(patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    func desiredJumpTargetCount(for plan: BurnBarSearchPlan) -> Int {
        max(1, min(plan.requestedResultCount ?? 5, 24))
    }

    func exactMatchScanLimit(for desiredCount: Int) -> Int {
        max(12, min(desiredCount * 4, 200))
    }

    func sanitizedLocalOracleContext(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = String(line)
                return Self.looksLikeLocalOracleInstructionInjection(trimmed)
                    ? "[redacted untrusted indexed line]"
                    : trimmed
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to the exact snippets.", with: "")
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to exact transcript locations.", with: "")
            .replacingOccurrences(of: "Use the matched-session buttons below to jump to the exact spot.", with: "")
            .replacingOccurrences(of: "Matched-session buttons below jump into the top-ranked provider’s sessions.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
