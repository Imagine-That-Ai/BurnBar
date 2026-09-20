import Foundation
import OpenBurnBarKernel

// MARK: - Conversation overlay (no transcript body)

/// Metadata needed to title, summarize, and link a receipt to its chat
/// without decrypting `fullText` / `lastAssistantMessage` overflow pages.
struct ReceiptConversationOverlay: Equatable, Sendable, Hashable {
    let conversationID: String
    let sessionID: String
    let inferredTaskTitle: String
    let summary: String?
    let summaryTitle: String?
    let workingDirectory: String?
    let messageCount: Int
    let keyFiles: [String]

    /// Overlays are stored under both `conversations.id` and
    /// `conversations.sessionId`. Receipts have been minted against either.
    static func lookup(
        _ sessionID: String,
        in map: [String: ReceiptConversationOverlay]
    ) -> ReceiptConversationOverlay? {
        if let hit = map[sessionID] { return hit }
        return map.values.first {
            $0.sessionID == sessionID || $0.conversationID == sessionID
        }
    }
}

// MARK: - Receipt ↔ chat bridge

/// The receipts register used to print cost, cache, and a SHA-256 seal, then
/// fall back to "Session completed successfully" whenever git proof or a
/// prompt title was missing. That is a thermal slip, not a receipt for a chat.
///
/// This type is the join: pick a human summary of what was *said*, mint the
/// `openburnbar://sessions/…` link Session Logs already understands, and
/// decide whether an accomplishment line is real or the generic placeholder.
enum ReceiptChatBridge: Sendable {
    static let genericAccomplishment = "Session completed successfully"

    static let sessionURLPrefix = "openburnbar://sessions/"
    static let receiptURLPrefix = "openburnbar://receipts/"

    // MARK: Generic copy

    static func isGenericAccomplishment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.caseInsensitiveCompare(genericAccomplishment) == .orderedSame {
            return true
        }
        // "Session completed in OpenBurnBar" / "Session completed in /private/tmp"
        if trimmed.lowercased().hasPrefix("session completed") { return true }
        return false
    }

    static func isGenericTitle(_ text: String, projectName: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isGenericAccomplishment(trimmed) { return true }
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty, trimmed.caseInsensitiveCompare(project) == .orderedSame {
            return true
        }
        return false
    }

    // MARK: Summary

    /// One or two sentences that answer "what was this chat about?"
    ///
    /// Preference order, each a better answer than the last:
    /// 1. the stored conversation summary (LLM or on-demand)
    /// 2. the generated session title
    /// 3. the inferred first-user-prompt title
    /// 4. the receipt's own prompt summary
    /// 5. a non-generic accomplishment
    /// 6. the first user turn parsed from `fullText` (only when the caller
    ///    already loaded a transcript — list rows must not)
    /// 7. a turn-count line when we know there was a chat
    static func contentSummary(
        receipt: ReceiptRecord,
        overlay: ReceiptConversationOverlay? = nil,
        transcript: ConversationRecord? = nil
    ) -> String {
        let project = receipt.projectName
        let candidates: [String] = [
            overlay?.summary,
            overlay?.summaryTitle,
            overlay.map(\.inferredTaskTitle),
            transcript?.summary,
            transcript?.summaryTitle,
            transcript?.inferredTaskTitle,
            receipt.promptSummary,
            receipt.actualAccomplishments.first(where: { !isGenericAccomplishment($0) })
        ].compactMap { $0 }

        if let hit = candidates.first(where: { !isGenericTitle($0, projectName: project) }) {
            return compressSummary(hit)
        }

        if let fullText = transcript?.fullText, !fullText.isEmpty,
           let prompt = firstUserPrompt(from: fullText),
           !isGenericTitle(prompt, projectName: project) {
            return compressSummary(prompt)
        }

        let turns = overlay?.messageCount ?? transcript?.messageCount ?? 0
        if turns > 0 {
            return "\(turns)-turn chat in \(project)"
        }
        return ""
    }

    /// List / flyout headline. Never leads with the generic placeholder.
    static func listPreview(
        receipt: ReceiptRecord,
        overlay: ReceiptConversationOverlay? = nil
    ) -> String {
        let summary = contentSummary(receipt: receipt, overlay: overlay)
        if !summary.isEmpty { return summary }
        if let first = receipt.actualAccomplishments.first, !isGenericAccomplishment(first) {
            return first
        }
        return "Untitled chat in \(receipt.projectName)"
    }

    static func firstUserPrompt(from fullText: String) -> String? {
        let blocks = TranscriptBlockParser.parse(fullText)
        guard let user = blocks.first(where: { $0.kind == .userMessage }) else { return nil }
        let trimmed = user.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func compressSummary(_ text: String, maxCharacters: Int = 220) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters)
        if let space = collapsed[..<end].lastIndex(of: " ") {
            return String(collapsed[..<space]) + "…"
        }
        return String(collapsed[..<end]) + "…"
    }

    // MARK: Links

    static func sessionURL(conversationID: String) -> URL? {
        burnbarURL(host: "sessions", path: conversationID)
    }

    static func receiptURL(receiptID: String, lens: ReceiptLens? = nil) -> URL? {
        burnbarURL(
            host: "receipts",
            path: receiptID,
            query: lens.map { ["lens": $0.deepLinkToken] }
        )
    }

    /// Path identity, already percent-decoded by `URL`.
    ///
    /// Subagent ids can contain a slash (`parentSession/agentId`). Join
    /// every non-empty component so banner taps do not truncate them.
    /// `openburnbar://receipts/` must not become an empty-string id.
    static func pathIdentifier(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    static func isOpenBurnBarURL(_ url: URL, host: String) -> Bool {
        url.scheme?.lowercased() == "openburnbar"
            && url.host?.lowercased() == host.lowercased()
    }

    static func sessionID(from url: URL) -> String? {
        guard isOpenBurnBarURL(url, host: "sessions") else { return nil }
        return pathIdentifier(from: url)
    }

    static func receiptID(from url: URL) -> String? {
        guard isOpenBurnBarURL(url, host: "receipts") else { return nil }
        return pathIdentifier(from: url)
    }

    static func receiptLens(from url: URL) -> ReceiptLens? {
        guard isOpenBurnBarURL(url, host: "receipts") else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let raw = items?.first(where: { $0.name.lowercased() == "lens" })?.value
        return ReceiptLens.fromDeepLinkToken(raw)
    }

    private static func burnbarURL(
        host: String,
        path: String,
        query: [String: String]? = nil
    ) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "openburnbar"
        components.host = host
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? trimmed
        components.percentEncodedPath = "/" + encoded
        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    /// Best conversation identity for a receipt. Receipts have been minted
    /// against either `conversations.id` or `conversations.sessionId`.
    static func conversationID(
        receipt: ReceiptRecord,
        overlay: ReceiptConversationOverlay?
    ) -> String {
        conversationLookupKeys(receipt: receipt, overlay: overlay).first ?? receipt.sessionId
    }

    /// Keys to try when loading the indexed transcript. Overlay conversation
    /// id first, then session id, then the receipt's own session key — slips
    /// have been minted against any of the three.
    static func conversationLookupKeys(
        receipt: ReceiptRecord,
        overlay: ReceiptConversationOverlay?
    ) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            keys.append(trimmed)
        }
        add(overlay?.conversationID)
        add(overlay?.sessionID)
        add(receipt.sessionId)
        return keys
    }

    static func revealURL(workingDirectory: String?, relativePath: String? = nil) -> URL? {
        let root = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let relativePath, !relativePath.isEmpty {
            if relativePath.hasPrefix("/") {
                return URL(fileURLWithPath: relativePath)
            }
            if !root.isEmpty {
                return URL(fileURLWithPath: root).appendingPathComponent(relativePath)
            }
            return nil
        }
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root)
    }
}
