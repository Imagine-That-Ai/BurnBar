// MemoryServing.swift
//
// FROZEN CONTRACT for the semantic-memory subsystem (mem0-class).
// Implemented by the backend track (docs/MEMORY_BACKEND_PLAN.md), consumed by the
// frontend / chat-integration track (docs/MEMORY_FRONTEND_PLAN.md). Lives in
// OpenBurnBarCore so the app, the test targets, and the iOS module can all import it
// without an Xcode target edit.
//
// Discipline (see docs/MEMORY_STRATEGY_AUDIT.md):
//   * Fact bodies are SEALED references, never plaintext at rest (gate G1). The
//     `bodyRedacted` field carries a snapshot reference, not the fact text.
//   * `MemorySnippet.text` is decrypted transiently for prompt injection only and is
//     NEVER logged or persisted.
//   * Recall returns approved + non-superseded memories only (gates G2/G4); the
//     frontend must wrap every snippet via LLMSafeContent.wrapUntrusted (gate G8).
//
// This file is the integration seam between two parallel implementers. Treat its
// public surface as frozen; coordinate any change across both tracks.

import Foundation

public typealias MemoryID = String
public typealias MemoryEventID = String

// MARK: - Enumerations

public enum MemorySourceKind: String, Codable, Sendable {
    case chat
    case code
    /// Usage-memory lane: a durable fact inferred from a Safari ask the member
    /// volunteered (prompt + page identity + answer digest). Consent-gated
    /// separately from chat memory; always quarantined on write.
    case safariAsk = "safari_ask"
    /// Usage-memory lane: a durable fact mined from a recorded agent session
    /// rollout (user turns and repeated workflows). Same consent + review
    /// posture as `safariAsk`.
    case agentSession = "agent_session"
    case agent  // Memory MCP engine memory: member content blind sync replicates.

    /// The passive usage-memory kinds. They share one storage partition
    /// (`usage:` project-id prefix) so exact dedup and corroboration work
    /// across sources; chat and code stay in their own partitions.
    public static var usageKinds: Set<MemorySourceKind> { [.safariAsk, .agentSession] }
}

/// Vocabulary for `memory_provenance.source_kind`. This is a per-citation
/// namespace and deliberately distinct from the authority table's
/// `MemorySourceKind` (the existing chat rows store `chat_message`, not `chat`).
public enum MemoryProvenanceSourceKind: String, Codable, Sendable {
    case chatMessage = "chat_message"
    case safariAsk = "safari_ask"
    case agentSessionEvent = "agent_session_event"
}

public enum MemoryKind: String, Codable, Sendable {
    case fact
    case preference
    case event
    case profile
    case relationship
    case other
}

public enum MemoryReviewStatus: String, Codable, Sendable {
    case quarantined   // default for new memories — cannot inject or replicate (G4)
    case approved      // injectable + replicable
    case rejected
    /// The authority record remains as a metadata tombstone after a user forgets it.
    /// Its sealed body is removed and it is never eligible for recall.
    case forgotten
}

/// Trust classification resolved server-side against the canonical chat row at
/// injection time (G8). Never trust a value carried on the memory record itself.
public enum MemoryTrustTier: String, Codable, Sendable {
    case untrusted        // default — wrap in <UNTRUSTED_CONTENT>, never persona voice
    case userAttested     // derived from a user-authored message
    case assistantDerived // derived from a prior assistant message (still untrusted)
}

public enum MemoryCitationState: String, Codable, Sendable {
    case live
    case sourcePruned   // source message deleted/GC'd; fact retained, citation flagged
    case tombstoned
}

public enum MemoryEventStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case merged
    case superseded
    case failed
    case skipped
}

// MARK: - Scope

/// mem0-style scope keys. Chat memories carry user/agent/run/app; code memories carry projectID.
public struct MemoryScope: Codable, Sendable, Equatable {
    public var userID: String?
    public var agentID: String?
    public var runID: String?
    public var appID: String?
    public var projectID: String?

    public init(
        userID: String? = nil,
        agentID: String? = nil,
        runID: String? = nil,
        appID: String? = nil,
        projectID: String? = nil
    ) {
        self.userID = userID
        self.agentID = agentID
        self.runID = runID
        self.appID = appID
        self.projectID = projectID
    }
}

// MARK: - Provenance / citation

/// One source citation for a memory. Memories are many-to-one over citations: a fact
/// corroborated across threads cites all of its sources (Codex P1). The cross-device
/// HMAC is the stable identity; `messageID` is the same-device jump target.
public struct MemoryCitation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var threadLogicalID: String      // content-derived, cross-device stable
    public var messageID: String?           // device-local jump id when available
    public var role: String                 // "user" | "assistant" (never tool/derived)
    public var authoredAt: Date
    public var contentHash: String
    public var occurrence: Int
    public var crossDeviceHMAC: String       // HMAC over the canonical source-event envelope
    public var citationState: MemoryCitationState

    public init(
        id: String,
        threadLogicalID: String,
        messageID: String? = nil,
        role: String,
        authoredAt: Date,
        contentHash: String,
        occurrence: Int = 0,
        crossDeviceHMAC: String,
        citationState: MemoryCitationState = .live
    ) {
        self.id = id
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.role = role
        self.authoredAt = authoredAt
        self.contentHash = contentHash
        self.occurrence = occurrence
        self.crossDeviceHMAC = crossDeviceHMAC
        self.citationState = citationState
    }
}

// MARK: - Records

/// The authority record. `bodyRedacted` is a sealed-snapshot reference (G1) — the fact
/// text lives only in the sealed store and is fetched transiently for `recallForPrompt`.
public struct Memory: Codable, Sendable, Identifiable, Equatable {
    public var id: MemoryID
    public var sourceKind: MemorySourceKind
    public var kind: MemoryKind
    public var scope: MemoryScope
    public var confidence: Double
    public var bodyRedacted: String
    public var reviewStatus: MemoryReviewStatus
    public var citations: [MemoryCitation]
    public var validFrom: Date
    public var validTo: Date?
    public var supersededBy: MemoryID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: MemoryID,
        sourceKind: MemorySourceKind = .chat,
        kind: MemoryKind,
        scope: MemoryScope,
        confidence: Double,
        bodyRedacted: String,
        reviewStatus: MemoryReviewStatus = .quarantined,
        citations: [MemoryCitation] = [],
        validFrom: Date,
        validTo: Date? = nil,
        supersededBy: MemoryID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.bodyRedacted = bodyRedacted
        self.reviewStatus = reviewStatus
        self.citations = citations
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A recall result ready for prompt assembly. `text` is the transiently-decrypted fact
/// body; the frontend MUST wrap it via LLMSafeContent.wrapUntrusted before injection (G8)
/// and MUST NOT place it in the trusted persona region.
public struct MemorySnippet: Sendable, Equatable, Identifiable {
    public var id: MemoryID { memoryID }
    public var memoryID: MemoryID
    public var text: String
    public var kind: MemoryKind
    public var confidence: Double
    public var citations: [MemoryCitation]
    public var trustTier: MemoryTrustTier
    public var tokenCountEstimate: Int

    public init(
        memoryID: MemoryID,
        text: String,
        kind: MemoryKind,
        confidence: Double,
        citations: [MemoryCitation],
        trustTier: MemoryTrustTier = .untrusted,
        tokenCountEstimate: Int
    ) {
        self.memoryID = memoryID
        self.text = text
        self.kind = kind
        self.confidence = confidence
        self.citations = citations
        self.trustTier = trustTier
        self.tokenCountEstimate = tokenCountEstimate
    }
}

// MARK: - Requests

public struct MemoryAddRequest: Sendable {
    /// Raw fact text to seal + store directly (the worker uses this after extraction).
    public var text: String
    public var kind: MemoryKind
    public var scope: MemoryScope
    public var confidence: Double
    public var citations: [MemoryCitation]
    public var reviewStatus: MemoryReviewStatus

    public init(
        text: String,
        kind: MemoryKind = .fact,
        scope: MemoryScope,
        confidence: Double = 0.6,
        citations: [MemoryCitation] = [],
        reviewStatus: MemoryReviewStatus = .quarantined
    ) {
        self.text = text
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.citations = citations
        self.reviewStatus = reviewStatus
    }
}

/// Enqueued on the explicit terminal assistant-commit event (G3). The worker drains the
/// durable outbox idempotently keyed on `idempotencyKey`.
public struct ExtractionIntent: Sendable {
    public var threadID: String
    public var threadLogicalID: String
    public var messageID: String
    public var scope: MemoryScope
    public var promptVersion: String
    public var idempotencyKey: String

    public init(
        threadID: String,
        threadLogicalID: String,
        messageID: String,
        scope: MemoryScope,
        promptVersion: String,
        idempotencyKey: String
    ) {
        self.threadID = threadID
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.scope = scope
        self.promptVersion = promptVersion
        self.idempotencyKey = idempotencyKey
    }
}

public struct MemoryQuery: Sendable {
    public var text: String
    public var scope: MemoryScope
    public var limit: Int

    public init(text: String, scope: MemoryScope, limit: Int = 20) {
        self.text = text
        self.scope = scope
        self.limit = limit
    }
}

public struct MemoryRecallRequest: Sendable {
    public var query: String
    public var scope: MemoryScope
    /// Token budget the frontend's prompt arbiter allocates to memory (G9). The backend
    /// returns snippets whose summed `tokenCountEstimate` fits within this budget.
    public var tokenBudget: Int
    public var limit: Int

    public init(query: String, scope: MemoryScope, tokenBudget: Int, limit: Int = 8) {
        self.query = query
        self.scope = scope
        self.tokenBudget = tokenBudget
        self.limit = limit
    }
}

public struct MemoryPageRequest: Sendable {
    public var scope: MemoryScope
    public var page: Int
    public var pageSize: Int
    public var includeQuarantined: Bool

    public init(scope: MemoryScope, page: Int = 1, pageSize: Int = 50, includeQuarantined: Bool = false) {
        self.scope = scope
        self.page = page
        self.pageSize = pageSize
        self.includeQuarantined = includeQuarantined
    }
}

public struct MemoryPage: Sendable {
    public var items: [Memory]
    public var page: Int
    public var pageSize: Int
    public var total: Int

    public init(items: [Memory], page: Int, pageSize: Int, total: Int) {
        self.items = items
        self.page = page
        self.pageSize = pageSize
        self.total = total
    }
}

public struct MemoryPatch: Sendable {
    public var text: String?
    public var kind: MemoryKind?
    public var confidence: Double?

    public init(text: String? = nil, kind: MemoryKind? = nil, confidence: Double? = nil) {
        self.text = text
        self.kind = kind
        self.confidence = confidence
    }
}

public struct MemoryEntity: Sendable, Equatable {
    public var keyName: String   // "user_id" | "agent_id" | "run_id" | "app_id" | "project_id"
    public var value: String
    public var count: Int

    public init(keyName: String, value: String, count: Int) {
        self.keyName = keyName
        self.value = value
        self.count = count
    }
}

// MARK: - The contract

public protocol MemoryServing: Sendable {
    // mem0 CRUD — mutations return an event_id; poll eventStatus(_:)
    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID
    func search(_ query: MemoryQuery) async throws -> [Memory]
    func get(id: MemoryID) async throws -> Memory?
    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage
    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID
    func delete(id: MemoryID) async throws -> MemoryEventID            // fact-level two-phase forget (G5)
    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID
    func listEntities() async throws -> [MemoryEntity]
    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus

    /// Frontend's single recall entry point. Returns version-floored, approved-only,
    /// ranked snippets within `tokenBudget`, each carrying provenance for citations.
    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet]

    // Review lifecycle (G4)
    func approve(id: MemoryID) async throws -> MemoryEventID
    func reject(id: MemoryID) async throws -> MemoryEventID

    /// Extraction trigger entry — frontend calls this on the explicit terminal
    /// assistant-commit event (G3). Idempotent on `intent.idempotencyKey`.
    func enqueueExtraction(_ intent: ExtractionIntent) async throws
}
