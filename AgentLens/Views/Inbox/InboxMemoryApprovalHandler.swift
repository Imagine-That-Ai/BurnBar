import Foundation
import CryptoKit
import OpenBurnBarKernel

/// Routes an inbox-proposed memory into the app's existing memory authority.
///
/// This is deliberately NOT a new storage path. An inbox proposal takes exactly
/// the same route a chat-extracted memory takes:
///
///   `addChatMemoryAuthorityRecord` (secret/PII gate → sealed body snapshot →
///   provenance rows → `memory.add` audit event → dedupe), landing
///   **quarantined**, followed by `setChatMemoryReviewStatus(.approved)` which
///   writes the `memory.approve` audit event.
///
/// Two things follow from that, and both are the point:
///   • The inbox cannot become a side channel around a control the rest of the
///     app enforces — the same gate that rejects a secret in chat rejects it here.
///   • An approved fact is indistinguishable downstream from any other approved
///     memory, so it participates in recall (`recallChatMemorySnippets` filters
///     on `.approved`) without any special-casing.
///
/// Nothing is auto-approved. The user pressing "Remember this" IS the approval.
@MainActor
struct InboxMemoryApprovalHandler {
    /// Namespace for provenance labels, so an inbox-derived memory is traceable
    /// back to the item that proposed it.
    static let provenancePrefix = "ai-inbox:item:"
    /// Namespace for plan-derived memories (Founder Plan Ledger).
    static let planProvenancePrefix = "ai-inbox:plan:"

    private let store: ControlPlaneStore
    private let scope: MemoryScope
    /// Pushes the refreshed approved-snippet set to the daemon after a write,
    /// so the headless tick can cite the fact (loophole L21). Optional: the
    /// approval itself must succeed even when the daemon is down.
    private let exporter: (@MainActor () async -> Void)?

    init(
        store: ControlPlaneStore,
        scope: MemoryScope,
        exporter: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.scope = scope
        self.exporter = exporter
    }

    func approve(candidate: BurnBarInboxMemoryCandidate, itemFingerprint: String) async throws {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { throw InboxMemoryApprovalError.emptyText }

        let request = MemoryAddRequest(
            text: text,
            kind: Self.memoryKind(for: candidate.kind),
            scope: scope,
            confidence: candidate.confidence,
            citations: citations(for: candidate, itemFingerprint: itemFingerprint),
            // Explicit even though it is the default: an inbox proposal must
            // never be able to write an already-approved row.
            reviewStatus: .quarantined
        )

        // Two steps rather than one, on purpose. Writing quarantined first means
        // a failure between the calls leaves an unapproved (harmless) row rather
        // than an approved one the user never saw.
        let memory = try await store.addChatMemoryAuthorityRecord(request)
        _ = try await store.setChatMemoryReviewStatus(id: memory.id, status: .approved)
        await exporter?()
    }

    /// "Remember" for an accepted Founder Plan step: the plan's commitment
    /// becomes a durable approved fact through the exact same quarantine-first
    /// route, with provenance `ai-inbox:plan:<planId>:step:<stepId>`. Returns
    /// the memory id so the caller can link it back onto the plan row.
    @discardableResult
    func approvePlanStep(plan: BurnBarInboxPlan, step: BurnBarInboxPlanStep) async throws -> String {
        let text = "\(plan.title): \(step.title). \(step.bodyMarkdown)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { throw InboxMemoryApprovalError.emptyText }

        let provenanceID = "\(Self.planProvenancePrefix)\(plan.id):step:\(step.id)"
        let now = Date()
        let request = MemoryAddRequest(
            text: text,
            kind: .fact,
            scope: scope,
            confidence: 0.9,
            citations: [
                MemoryCitation(
                    id: provenanceID,
                    threadLogicalID: provenanceID,
                    messageID: nil,
                    role: "assistant",
                    authoredAt: now,
                    contentHash: Self.hash(text),
                    occurrence: 0,
                    crossDeviceHMAC: Self.hash(provenanceID),
                    citationState: .live
                )
            ],
            reviewStatus: .quarantined
        )

        let memory = try await store.addChatMemoryAuthorityRecord(request)
        _ = try await store.setChatMemoryReviewStatus(id: memory.id, status: .approved)
        await exporter?()
        return memory.id
    }

    /// Builds provenance rows pointing back at the conversations that justified
    /// the fact, plus one synthetic citation naming the inbox item itself.
    private func citations(
        for candidate: BurnBarInboxMemoryCandidate,
        itemFingerprint: String
    ) -> [MemoryCitation] {
        let now = Date()
        var rows: [MemoryCitation] = candidate.citationConversationIDs.prefix(6).map { conversationID in
            MemoryCitation(
                id: "\(Self.provenancePrefix)\(itemFingerprint):\(conversationID)",
                threadLogicalID: conversationID,
                messageID: nil,
                role: "assistant",
                authoredAt: now,
                contentHash: Self.hash(candidate.text),
                occurrence: 0,
                crossDeviceHMAC: Self.hash("\(itemFingerprint):\(conversationID)"),
                citationState: .live
            )
        }
        rows.append(
            MemoryCitation(
                id: "\(Self.provenancePrefix)\(itemFingerprint)",
                threadLogicalID: "\(Self.provenancePrefix)\(itemFingerprint)",
                messageID: nil,
                role: "assistant",
                authoredAt: now,
                contentHash: Self.hash(candidate.text),
                occurrence: 0,
                crossDeviceHMAC: Self.hash(itemFingerprint),
                citationState: .live
            )
        )
        return rows
    }

    /// Maps the analyst's free-form kind hint onto the memory taxonomy.
    /// Unknown hints become `.fact`, which is the conservative default.
    static func memoryKind(for hint: String) -> MemoryKind {
        switch hint.lowercased() {
        case "preference": return .preference
        case "decision", "event": return .event
        case "profile": return .profile
        case "relationship": return .relationship
        case "convention", "gotcha", "context", "fact": return .fact
        default: return .fact
        }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum InboxMemoryApprovalError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "This proposal has no text to remember."
        }
    }
}
