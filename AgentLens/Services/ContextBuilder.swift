import Foundation

// MARK: - Chat context budgets (CLI-friendly totals)

enum OpenBurnBarChatContextBudget {
    /// Persona + health + ephemeral usage rollup.
    static let maxBasePromptChars = 8_000
    /// Hybrid retrieval excerpts appended per user message.
    static let maxEvidenceChars = 18_000
    /// When the same session is already in retrieved evidence.
    static let maxFocusWhenDuplicateChars = 2_000
    /// User-picked session not present (or weakly present) in evidence.
    static let maxFocusStandaloneChars = 6_000
    /// Wider funnel for hybrid retrieval (lexical + dense); still capped by `maxEvidenceChars`.
    static let chatRetrievalResultLimit = 16
    static let chatRetrievalMaxResultLimit = 48
    static let chatLexicalCandidateLimit = 96
    static let chatSemanticCandidateLimit = 96
    static let chatRerankCandidateLimit = 144
}

// MARK: - Retrieved evidence pack (pure formatting for tests)

enum OpenBurnBarChatEvidenceFormatting {
    /// Formats hybrid retrieval hits for the dashboard analyst. Dedupes multiple chunks from the same conversation (`conversation.id` or `sourceID` fallback).
    static func formatPack(results: [RetrievalResult], maxTotalChars: Int) -> String {
        var lines: [String] = []
        lines.append("## Retrieved evidence")
        lines.append(
            "Ground factual claims in these excerpts. When citing an item, mention its chunk_id. If this section is empty or insufficient, say so—do not invent sessions or documents."
        )
        if results.isEmpty {
            lines.append("")
            lines.append("_No matching indexed excerpts were retrieved for this question._")
            return lines.joined(separator: "\n")
        }

        var used = lines.joined(separator: "\n").count + 1
        var seenConversationKeys = Set<String>()
        var ordinal = 0

        for r in results {
            guard used < maxTotalChars else { break }

            if r.sourceKind == .conversation {
                let key = r.conversation?.id ?? r.sourceID
                if seenConversationKeys.contains(key) { continue }
                seenConversationKeys.insert(key)
            }

            ordinal += 1
            let blockLines = formatBlock(ordinal: ordinal, result: r)
            var block = blockLines.joined(separator: "\n")
            if used + block.count > maxTotalChars {
                let remaining = max(0, maxTotalChars - used - 20)
                if remaining < 80 { break }
                block = truncateBlock(block, maxChars: remaining)
            }
            lines.append("")
            lines.append(block)
            used += block.count + 1
        }

        if used >= maxTotalChars - 40 {
            lines.append("")
            lines.append("_Evidence truncated to respect size limits._")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatBlock(ordinal: Int, result: RetrievalResult) -> [String] {
        var out: [String] = []
        out.append("### \(ordinal). chunk_id: `\(result.chunkID)`")
        out.append("- source_kind: \(result.sourceKind.rawValue)")
        if let p = result.provider {
            out.append("- provider: \(p.rawValue)")
        } else if let raw = result.providerRawValue, !raw.isEmpty {
            out.append("- provider: \(raw)")
        }
        if let proj = result.projectName, !proj.isEmpty {
            out.append("- project: \(proj)")
        }
        if !result.sourceID.isEmpty {
            out.append("- source_id: \(result.sourceID)")
        }
        out.append("- title: \(result.title)")
        if let sub = result.subtitle, !sub.isEmpty {
            out.append("- subtitle: \(sub)")
        }
        if let path = result.sectionPath, !path.isEmpty {
            out.append("- section: \(path)")
        }
        out.append("- offsets: \(result.startOffset)–\(result.endOffset)")
        out.append("- snippet:")
        out.append(result.snippet)
        return out
    }

    private static func truncateBlock(_ block: String, maxChars: Int) -> String {
        guard block.count > maxChars else { return block }
        return String(block.prefix(maxChars)) + "\n…"
    }

    /// Deterministic aggregate counts over `conversations.fullText` (for “how many times…” questions).
    static func formatAggregateSection(
        patterns: [String],
        totalOccurrences: Int?,
        windowDescription: String? = nil
    ) -> String {
        guard let total = totalOccurrences else { return "" }
        var lines: [String] = []
        lines.append("## Aggregate over indexed transcripts (`conversations.fullText`)")
        lines.append("Total substring occurrences (case-insensitive, summed across patterns): **\(total)**")
        if !patterns.isEmpty {
            lines.append("Patterns counted: \(patterns.joined(separator: ", "))")
        }
        if let windowDescription, windowDescription.isEmpty == false {
            lines.append(windowDescription)
        }
        lines.append(
            "_This is a full scan over stored transcript text for the patterns above, not top‑K semantic retrieval._"
        )
        return lines.joined(separator: "\n")
    }

    static func composeEvidenceAndAggregate(retrievalPack: String, aggregateSection: String) -> String {
        let agg = aggregateSection.trimmingCharacters(in: .whitespacesAndNewlines)
        if agg.isEmpty { return retrievalPack }
        return retrievalPack + "\n\n" + agg
    }
}

// MARK: - Context Builder

enum ContextBuilder {
    private static let maxPromptChars = 6_000

    static func buildSystemPrompt(
        from dataStore: DataStore,
        intelligenceService: SearchService? = nil
    ) async -> String {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let retrieval = await MainActor.run {
            intelligenceService ?? SearchService.makeConversationSearchService(dataStore: dataStore)
        }

        let allUsages = await MainActor.run { dataStore.usages }
        let recentUsages = allUsages
            .filter { $0.startTime >= weekAgo }
            .sorted { $0.startTime > $1.startTime }

        var lines: [String] = []
        lines.append("You are OpenBurnBar's in-app AI coding assistant with access to this developer's recent agent session history.")
        lines.append("This product is named OpenBurnBar. Never refer to it as Agent Lens or AgentLens.")
        lines.append("")
        lines.append("## Recent work (last 7 days)")

        let conversations = await MainActor.run { retrieval.recentConversations(limit: 80) }
        let convBySession = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        for usage in recentUsages.prefix(24) {
            let cid = ConversationRecord.stableId(provider: usage.provider, sessionId: usage.sessionId)
            let conv = convBySession[cid]
            let title = conv?.inferredTaskTitle ?? usage.projectName
            let day = usage.startTime.formatted(date: .abbreviated, time: .omitted)
            let hours = max(usage.duration / 3600, 0.01)
            let files = conv?.keyFiles.prefix(2).joined(separator: ", ") ?? ""
            let fileSuffix = files.isEmpty ? "" : " — Files: \(files)"
            lines.append("- \(title) (\(day), \(String(format: "%.1f", hours))h, \(usage.cost.formatAsCost()))\(fileSuffix)")
        }

        lines.append("")
        lines.append("## This week's token spend")

        let weekUsages = allUsages.filter { $0.startTime >= weekAgo }
        var modelCost: [String: Double] = [:]
        var projectCost: [String: Double] = [:]
        for u in weekUsages {
            modelCost[u.model, default: 0] += u.cost
            projectCost[u.projectName, default: 0] += u.cost
        }
        let totalWeek = weekUsages.reduce(0.0) { $0 + $1.cost }
        for (model, cost) in modelCost.sorted(by: { $0.value > $1.value }).prefix(6) {
            let pct = totalWeek > 0 ? (cost / totalWeek) * 100 : 0
            lines.append("- \(model): \(String(format: "%.0f", pct))% (\(cost.formatAsCost()))")
        }
        if let topProj = projectCost.max(by: { $0.value < $1.value }) {
            lines.append("- Top project: \(topProj.key) (\(topProj.value.formatAsCost()))")
        }

        lines.append("")
        lines.append("## Where you left off")

        if let latest = await MainActor.run { retrieval.latestConversation(in: conversations) }, !latest.lastAssistantMessage.isEmpty {
            lines.append(latest.lastAssistantMessage)
        } else {
            lines.append("(No recent assistant message indexed yet.)")
        }

        lines.append("")
        lines.append("Answer the user's question using this context. Be concise and specific.")

        var result = lines.joined(separator: "\n")
        while result.count > maxPromptChars, lines.count > 8 {
            lines.remove(at: lines.count / 2)
            result = lines.joined(separator: "\n")
        }
        if result.count > maxPromptChars {
            result = String(result.prefix(maxPromptChars)) + "\n…"
        }
        return result
    }

    /// Dashboard chat: OpenBurnBar data analyst persona, index health, and non-exhaustive usage rollups. Does not include per-message retrieval (append `OpenBurnBarChatEvidenceFormatting.formatPack` separately).
    static func buildDatabaseAnalystSystemPrompt(
        from dataStore: DataStore,
        intelligenceService: SearchService? = nil,
        indexingEnabled: Bool,
        health: RetrievalSystemHealthSnapshot
    ) async -> String {
        let retrieval = await MainActor.run {
            intelligenceService ?? SearchService.makeConversationSearchService(dataStore: dataStore)
        }
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        var lines: [String] = []
        lines.append("You are OpenBurnBar’s local data analyst and index oracle for THIS Mac only.")
        lines.append(
            "You reason over OpenBurnBar’s local SQLite-backed index (conversations, derived chunks, skills/agent docs). You are not a generic coding agent unless the user explicitly asks for code help."
        )
        lines.append("Product name: OpenBurnBar. Never call it Agent Lens or AgentLens.")
        lines.append("")
        lines.append("Rules:")
        lines.append(
            "- Ground factual claims in **Retrieved evidence**, **## Aggregate over indexed transcripts** (exact substring counts over stored conversation text—authoritative for “how many times” questions), or **Ephemeral rollups** here. If the user asks for counts and an Aggregate section is present with a number, treat that total as the indexed answer for those patterns and time window—even when retrieved excerpts look unrelated."
        )
        lines.append(
            "- If none of those sections supports an answer, say you don’t have indexed support and avoid guessing."
        )
        lines.append("- Never invent sessions, costs, or transcript content.")
        lines.append("- Prefer concise bullets or small tables. Lead with the direct answer, then supporting points.")
        lines.append("- If retrieval is degraded or indexing is off, state uncertainty plainly.")
        lines.append("")

        lines.append("## Index and retrieval status")
        if !indexingEnabled {
            lines.append(
                "- Conversation indexing is **OFF**. Retrieved conversation excerpts may be missing; only enable-derived data and rollups below may apply."
            )
        } else {
            lines.append("- Conversation indexing is **ON** (projections may still be catching up—see degraded notes).")
        }
        if health.degradedModes.isEmpty {
            lines.append("- No active degraded-mode flags in the last health snapshot.")
        } else {
            for mode in health.degradedModes.prefix(8) {
                lines.append("- \(mode.title): \(mode.message)")
            }
        }
        if health.parserImport.status != .healthy {
            lines.append(
                "- Parser import: \(health.parserImport.status) — counts may be incomplete until logs are imported."
            )
        }
        if health.projectionQueue.status != .healthy, health.projectionQueue.queueDepth > 0 || health.projectionQueue.failedJobs > 0 {
            lines.append(
                "- Projection queue: depth \(health.projectionQueue.queueDepth), failed jobs \(health.projectionQueue.failedJobs)."
            )
        }
        if health.semanticPipeline.status != .healthy {
            lines.append("- Semantic pipeline: \(health.semanticPipeline.status.rawValue). Lexical retrieval may dominate.")
        }
        lines.append("")

        lines.append("## Ephemeral rollups (not exhaustive)")
        lines.append(
            "High-level usage from OpenBurnBar tables—**not** a substitute for retrieved excerpts. Use for spend/time questions when retrieval is thin."
        )

        let allUsages = await MainActor.run { dataStore.usages }
        let recentUsages = allUsages
            .filter { $0.startTime >= weekAgo }
            .sorted { $0.startTime > $1.startTime }

        let conversations = await MainActor.run { retrieval.recentConversations(limit: 80) }
        let convBySession = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        lines.append("")
        lines.append("### Recent work (last 7 days)")
        for usage in recentUsages.prefix(18) {
            let cid = ConversationRecord.stableId(provider: usage.provider, sessionId: usage.sessionId)
            let conv = convBySession[cid]
            let title = conv?.inferredTaskTitle ?? usage.projectName
            let day = usage.startTime.formatted(date: .abbreviated, time: .omitted)
            let hours = max(usage.duration / 3600, 0.01)
            let files = conv?.keyFiles.prefix(2).joined(separator: ", ") ?? ""
            let fileSuffix = files.isEmpty ? "" : " — Files: \(files)"
            lines.append("- \(title) (\(day), \(String(format: "%.1f", hours))h, \(usage.cost.formatAsCost()))\(fileSuffix)")
        }

        lines.append("")
        lines.append("### This week’s token spend (approximate mix)")
        let weekUsages = allUsages.filter { $0.startTime >= weekAgo }
        var modelCost: [String: Double] = [:]
        var projectCost: [String: Double] = [:]
        for u in weekUsages {
            modelCost[u.model, default: 0] += u.cost
            projectCost[u.projectName, default: 0] += u.cost
        }
        let totalWeek = weekUsages.reduce(0.0) { $0 + $1.cost }
        for (model, cost) in modelCost.sorted(by: { $0.value > $1.value }).prefix(5) {
            let pct = totalWeek > 0 ? (cost / totalWeek) * 100 : 0
            lines.append("- \(model): \(String(format: "%.0f", pct))% (\(cost.formatAsCost()))")
        }
        if let topProj = projectCost.max(by: { $0.value < $1.value }) {
            lines.append("- Top project: \(topProj.key) (\(topProj.value.formatAsCost()))")
        }

        lines.append("")
        lines.append("### Latest indexed assistant line (may be unrelated to the user question)")
        if let latest = await MainActor.run { retrieval.latestConversation(in: conversations) }, !latest.lastAssistantMessage.isEmpty {
            lines.append(latest.lastAssistantMessage)
        } else {
            lines.append("(None yet.)")
        }

        var result = lines.joined(separator: "\n")
        while result.count > OpenBurnBarChatContextBudget.maxBasePromptChars, lines.count > 12 {
            lines.remove(at: lines.count / 2)
            result = lines.joined(separator: "\n")
        }
        if result.count > OpenBurnBarChatContextBudget.maxBasePromptChars {
            result = String(result.prefix(OpenBurnBarChatContextBudget.maxBasePromptChars)) + "\n…"
        }
        return result
    }

    /// Prepares session transcript for on-demand summarization (middle section dropped when very long).
    static func chunkedSessionContext(_ fullText: String) -> String {
        if fullText.count <= 80_000 { return fullText }
        let first = String(fullText.prefix(20_000))
        let last = String(fullText.suffix(60_000))
        return first + "\n\n… [middle section omitted for length] …\n\n" + last
    }

    static func summarizeSessionPrompt(fullText: String) -> String {
        let body = chunkedSessionContext(fullText)
        return """
        Summarize this coding session in exactly three short sentences: what was being built or fixed, what decisions were made, and what state things were left in. Be concrete.

        Session transcript:
        \(body)
        """
    }

    static func summarizeSessionJSONPrompt(fullText: String, maxChars: Int = 80_000) -> String {
        let trimmed: String
        if fullText.count > maxChars {
            trimmed = String(fullText.prefix(maxChars / 4))
                + "\n\n… [middle section omitted for length] …\n\n"
                + String(fullText.suffix(maxChars - (maxChars / 4)))
        } else {
            trimmed = fullText
        }

        return """
        You are generating a structured session summary for a coding transcript.
        Return strict JSON only with this schema:
        {"title":"string","summary":"string"}

        Rules:
        - title: 4-12 words, specific and searchable, no trailing punctuation.
        - summary: 2-4 short sentences with concrete technical details and current state.
        - no markdown, no code fences, no extra keys.

        Session transcript:
        \(trimmed)
        """
    }
}
