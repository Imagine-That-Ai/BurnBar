import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    func reconfigureSearchService() {
        searchQueryRevision += 1
        cancelCurrentSearch(clearResults: false)
        searchService = searchServiceFactory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
    }
    /// Combines the prior user turn with short replies like "yes please" so hybrid search still runs the original question.
    static func retrievalQueryText(for current: String, messages: [ChatMessageRecord]) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortAffirmation(trimmed), messages.count >= 2 else { return trimmed }
        let withoutLatest = messages.dropLast()
        guard let prior = withoutLatest.last(where: { $0.role == .user })?.content else { return trimmed }
        let p = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false, p.caseInsensitiveCompare(trimmed) != .orderedSame else { return trimmed }
        return "\(p) \(trimmed)"
    }

    static func isShortAffirmation(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 { return false }
        let known: Set<String> = [
            "yes", "yes please", "yeah", "yep", "sure", "ok", "okay", "please",
            "do it", "go ahead", "try again", "search", "go for it", "sounds good",
            "please do", "that works", "k", "yup", "absolutely", "please search",
            "do that", "run it"
        ]
        if known.contains(t) { return true }
        if t.hasPrefix("yes ") || t.hasPrefix("sure ") || t.hasPrefix("ok ") { return true }
        return false
    }

    static func indexedQueryResponseStrategy(
        queryText: String,
        plan: BurnBarSearchPlan,
        hasJumpTargets: Bool,
        retrievalResultCount: Int
    ) -> IndexedQueryResponseStrategy {
        let memoryQuestion = looksLikeConversationMemoryQuestion(queryText, plan: plan)
        guard memoryQuestion else { return .llmOnly }

        // Credential-shaped exact lookups are local-only even when the wording
        // also asks for synthesis. This check must precede the hybrid route or
        // transcript snippets can cross a model/provider boundary.
        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            return .localOracle
        }

        if requiresLLMSynthesis(queryText) {
            return .hybridIndexThenLLM
        }

        if plan.analysisIntent != .none || plan.aggregatePatterns.isEmpty == false {
            return .localOracle
        }

        if hasJumpTargets || retrievalResultCount > 0 {
            return .localOracle
        }

        return .localOracle
    }

    static let indexOracleNoiseWords: Set<String> = Set([
        "instance", "thread", "conversation", "session", "remember",
        "find", "search", "look", "where", "when", "ive", "entered", "enterd",
        "agent", "assistant", "provider", "model", "chat", "button", "buttons",
        "match", "matches", "result", "results", "show", "open", "jump", "exact"
    ])

    static func looksLikeLocalOracleInstructionInjection(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "4", with: "a")
            .replacingOccurrences(of: "5", with: "s")
        let indicators = [
            "ignore previous instructions",
            "ignore all previous",
            "disregard previous instructions",
            "from now on respond only",
            "from now on you must",
            "you are now",
            "new system prompt",
            "override system",
            "developer message:",
            "system message:",
            "<<sys>>",
            "<</sys>>",
            "ignora las instrucciones",
            "ignora instrucciones anteriores",
            "api key rotation complete",
            "paste your api key",
            "send your api key"
        ]
        return indicators.contains { normalized.contains($0) }
    }

    static func looksLikeConversationMemoryQuestion(_ queryText: String, plan: BurnBarSearchPlan) -> Bool {
        if plan.analysisIntent != .none || plan.aggregatePatterns.isEmpty == false {
            return true
        }

        if SearchService.looksLikeSensitiveExactLookup(queryText) {
            return true
        }

        let lower = queryText.lowercased()
        let memoryPatterns = [
            #"\b(thread|conversation|session|transcript|chat history|history|memory|memories)\b"#,
            #"\b(remember|remember when|that time|did i|have i|when did i|where did i|have we|did we)\b"#,
            #"\b(jump target|jump targets|matched session|matched sessions|exact match|exact phrase)\b"#
        ]
        if memoryPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        let hasQuotedPhrase = BurnBarFTSQueryBuilder.extractTokens(from: queryText).contains(where: \.isQuotedPhrase)
        if hasQuotedPhrase,
           lower.range(of: #"\b(find|search|show|open|jump|where|look up|lookup)\b"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    static func requiresLLMSynthesis(_ queryText: String) -> Bool {
        let lower = queryText.lowercased()
        let synthesisPatterns = [
            #"\b(why|explain|summarize|summary|analyze|analysis|compare|comparison|interpret|insight|pattern|patterns|trend|trends)\b"#,
            #"\b(what does that mean|what should i|should i|recommend|advice|help me understand|how come)\b"#
        ]
        return synthesisPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func appendStreamingText(_ chunk: String, to pieces: inout [ChatTranscriptPiece]) {
        appendStreamingTranscriptChunk(chunk, kind: .text, to: &pieces)
    }

    static func appendStreamingTranscriptChunk(
        _ chunk: String,
        kind: ChatTranscriptPiece.Kind,
        to pieces: inout [ChatTranscriptPiece]
    ) {
        guard !chunk.isEmpty else { return }
        if let i = pieces.indices.last, pieces[i].kind == kind {
            // Mutate through the subscript so the append stays amortized
            // O(1). The old copy-out (`var last = pieces[i]`) shared string
            // storage with the array element, forcing a full copy-on-write
            // of the accumulated value on EVERY chunk — O(n²) per stream.
            pieces[i].value += chunk
        } else {
            pieces.append(ChatTranscriptPiece(kind: kind, value: chunk, detail: nil))
        }
    }

    /// Loads bytes for attachments in `history` that the encoder will need.
    /// We pull bytes for all user messages (small overhead, keeps multi-turn
    /// vision threads honest if the user re-sends with image context).
    static func collectAttachmentBytes(
        history: [ChatMessageRecord],
        workspaceURL: URL
    ) -> [String: Data] {
        var map: [String: Data] = [:]
        for message in history where message.role == .user {
            for att in message.attachments {
                if map[att.id] != nil { continue }
                if let data = HermesAttachmentLoader.loadAttachmentBytes(att, workspaceURL: workspaceURL) {
                    map[att.id] = data
                }
            }
        }
        return map
    }
}

extension SearchService: ChatSessionSearchProviding {
    func search(query: String) async -> [SearchResult] {
        await search(query: query, provider: nil)
    }
}
