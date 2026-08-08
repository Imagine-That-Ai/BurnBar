import Foundation
import OpenBurnBarKernel

/// Turns an inbox evidence citation into a real Session Logs jump target.
///
/// Inbox evidence carries only a conversation id (`conv:<id>:<messageCount>`),
/// because the daemon publishes references rather than transcripts. Session Logs,
/// however, needs a full `ConversationJumpTarget` — the record itself plus a
/// snippet and byte offsets — to scroll to and highlight the right passage.
///
/// This resolver closes that gap at click time: it loads the record, then picks
/// the offsets that best answer *"why is this conversation the evidence?"*.
///
/// Landing on the relevant passage rather than the top of a 200-message
/// transcript is the difference between evidence you can check in two seconds and
/// evidence you take on faith.
@MainActor
struct InboxConversationJumpResolver {
    private let fetchConversation: @Sendable (String) async throws -> OpenBurnBarKernel.ConversationRecord?

    init(fetchConversation: @escaping @Sendable (String) async throws -> OpenBurnBarKernel.ConversationRecord?) {
        self.fetchConversation = fetchConversation
    }

    init(dataStore: DataStore) {
        self.init { id in try await dataStore.fetchConversation(id: id) }
    }

    /// Resolves a jump target, or `nil` when the conversation is no longer
    /// indexed (pruned, or the profile was reset) — in which case the caller
    /// should still navigate to Session Logs rather than doing nothing.
    func jumpTarget(
        conversationID: String,
        highlighting phrase: String? = nil
    ) async -> ConversationJumpTarget? {
        // `try?` flattens the optional here, so one binding covers both a thrown
        // error and a missing row.
        guard let record = try? await fetchConversation(conversationID) else { return nil }
        let text = record.fullText ?? ""
        let range = Self.bestRange(in: text, highlighting: phrase)

        return ConversationJumpTarget(
            conversation: record,
            snippet: Self.snippet(from: text, range: range),
            startOffset: range.lowerBound,
            endOffset: range.upperBound,
            // `retrieval`, not `aggregateExact`: the inbox surfaced this
            // conversation by relevance, not by an exact aggregate match, and the
            // jump UI styles the two differently.
            source: .retrieval
        )
    }

    /// Chooses the byte range to highlight.
    ///
    /// Preference order, each a better answer to "why this conversation?":
    ///   1. an explicit phrase the caller wants shown (e.g. the completion claim
    ///      that triggered a `promised_not_landed` item)
    ///   2. the last assistant turn — usually the outcome, which is what an
    ///      "is this actually finished?" item is about
    ///   3. the start of the transcript
    static func bestRange(in text: String, highlighting phrase: String?) -> Range<Int> {
        guard text.isEmpty == false else { return 0..<0 }
        let utf8Count = text.utf8.count

        if let phrase, phrase.isEmpty == false,
           let found = text.range(of: phrase, options: [.caseInsensitive]) {
            let start = text.utf8Offset(of: found.lowerBound)
            let end = text.utf8Offset(of: found.upperBound)
            return start..<min(end, utf8Count)
        }

        // Fall back to the tail, which is where an agent states what it did.
        let tailBytes = min(utf8Count, Self.tailWindowBytes)
        let start = max(0, utf8Count - tailBytes)
        return start..<utf8Count
    }

    /// How much of the transcript's tail to treat as "the outcome".
    static let tailWindowBytes = 1_200
    static let maxSnippetBytes = 400

    static func snippet(from text: String, range: Range<Int>) -> String {
        guard text.isEmpty == false, range.lowerBound < text.utf8.count else { return "" }
        let bytes = Array(text.utf8)
        let upper = min(range.upperBound, bytes.count)
        let lower = min(range.lowerBound, upper)
        let slice = Array(bytes[lower..<upper].prefix(maxSnippetBytes))
        return String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// UTF-8 byte offset of an index, matching how `ConversationJumpTarget`
    /// offsets are interpreted elsewhere in Session Logs.
    func utf8Offset(of index: String.Index) -> Int {
        utf8.distance(from: utf8.startIndex, to: index.samePosition(in: utf8) ?? utf8.startIndex)
    }
}
