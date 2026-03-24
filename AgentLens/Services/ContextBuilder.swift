import Foundation

// MARK: - Context Builder

enum ContextBuilder {
    private static let maxPromptChars = 6_000

    @MainActor
    static func buildSystemPrompt(
        from dataStore: DataStore,
        intelligenceService: SearchService? = nil
    ) -> String {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let retrieval = intelligenceService ?? SearchService(dataStore: dataStore)

        let recentUsages = dataStore.usages
            .filter { $0.startTime >= weekAgo }
            .sorted { $0.startTime > $1.startTime }

        var lines: [String] = []
        lines.append("You are BurnBar's in-app AI coding assistant with access to this developer's recent agent session history.")
        lines.append("This product is named BurnBar. Never refer to it as Agent Lens or AgentLens.")
        lines.append("")
        lines.append("## Recent work (last 7 days)")

        let conversations = retrieval.recentConversations(limit: 80)
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

        let weekUsages = dataStore.usages.filter { $0.startTime >= weekAgo }
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

        if let latest = retrieval.latestConversation(in: conversations), !latest.lastAssistantMessage.isEmpty {
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
