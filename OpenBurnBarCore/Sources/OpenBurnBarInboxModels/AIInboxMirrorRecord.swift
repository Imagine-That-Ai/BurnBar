import Foundation

// MARK: - AI Inbox cloud mirror
//
// The AI Inbox is produced on the Mac by the daemon and lives in the Mac's local
// SQLite. This file defines the ONE document shape that carries it to iPhone,
// iPad, and Android.
//
// ## Why a Firestore mirror rather than a live relay
//
// The inbox's entire premise is *"tell me what happened while I wasn't
// watching."* The moment a user reaches for their phone is precisely the moment
// the Mac is most likely to be asleep. Every live transport in this repo (the
// Hermes relay, Iroh P2P, mission dispatch) requires an awake, reachable Mac and
// has no store-and-forward. Firestore is the only path that is durable, works
// with the lid closed, serves an offline cache, and already has a
// Cloud-Function → FCM push story for "something new arrived".
//
// ## The plaintext/sealed split
//
// Sorting, filtering, badge counts, and the push trigger all need to work
// WITHOUT decrypting. So routing metadata (kind, priority, state, timestamps)
// stays top-level, while everything that reads like the user's own work — the
// title, the markdown body, the evidence, the memory proposals — is sealed into
// `sealedPayload` with the Cloud Vault, exactly as `cli_sessions` does.
//
// This mirrors the `CLIAgentSessionRecord` contract deliberately: same sealing
// helper, same AAD binding, same `sealedSchemaVersion: 2`, so the same
// `firestore.rules` predicates and the same client decrypt paths apply.

/// The sealed half of a mirrored inbox item: everything that reads like the
/// user's own work.
///
/// ## Porting note for non-Swift readers
///
/// This struct is encoded with ISO-8601 dates and sorted keys (see the private
/// `aiInboxCloudPayload` coders beside the codec). `kotlinx.serialization`
/// has no built-in `Date`, so the Kotlin mirror of this type must declare every
/// timestamp as `String` and parse it explicitly — a `@Serializable` class with a
/// `Long` there will fail to decode the whole payload, and because Kotlin's
/// decoder is configured with `ignoreUnknownKeys = true`, the failure surfaces as
/// an empty inbox rather than an error.
///
/// Sorted keys are deliberate: a sealed payload is then byte-reproducible for the
/// same input, which is what makes the round-trip tests meaningful.
public struct AIInboxMirrorPayload: Codable, Sendable, Hashable {
    public var title: String
    public var summaryMarkdown: String
    public var projectName: String?
    public var resolutionNote: String?
    public var payload: BurnBarInboxItemPayload

    public init(
        title: String,
        summaryMarkdown: String,
        projectName: String? = nil,
        resolutionNote: String? = nil,
        payload: BurnBarInboxItemPayload
    ) {
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.projectName = projectName
        self.resolutionNote = resolutionNote
        self.payload = payload
    }
}

/// One mirrored inbox item, as it exists on a phone or tablet.
///
/// Assembled from the top-level routing fields plus the opened `sealedPayload`.
/// Mobile clients never see a partially-decoded item: if the seal cannot be
/// opened, the row is dropped rather than shown with a blank body.
public struct AIInboxMirrorRecord: Codable, Sendable, Hashable, Identifiable {
    /// Bumped when the mirror shape changes in a way older clients cannot read.
    /// A client refuses to decode a document from the future.
    public static let currentSchemaVersion = 1

    public var id: String
    public var fingerprint: String
    public var kind: BurnBarInboxItemKind
    public var priority: BurnBarInboxPriority
    public var state: BurnBarInboxItemState
    public var occurrenceCount: Int
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var resolvedAt: Date?
    public var modelProvenance: String
    public var hasMemoryCandidates: Bool
    public var schemaVersion: Int

    // Sealed content, once opened.
    public var title: String
    public var summaryMarkdown: String
    public var projectName: String?
    public var resolutionNote: String?
    public var payload: BurnBarInboxItemPayload

    public var isOpen: Bool { state.isOpen }

    public init(
        id: String,
        fingerprint: String,
        kind: BurnBarInboxItemKind,
        priority: BurnBarInboxPriority,
        state: BurnBarInboxItemState,
        occurrenceCount: Int = 1,
        firstSeenAt: Date,
        lastSeenAt: Date,
        resolvedAt: Date? = nil,
        modelProvenance: String = "local-rules",
        hasMemoryCandidates: Bool = false,
        schemaVersion: Int = AIInboxMirrorRecord.currentSchemaVersion,
        title: String,
        summaryMarkdown: String,
        projectName: String? = nil,
        resolutionNote: String? = nil,
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload()
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.kind = kind
        self.priority = priority
        self.state = state
        self.occurrenceCount = occurrenceCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.resolvedAt = resolvedAt
        self.modelProvenance = modelProvenance
        self.hasMemoryCandidates = hasMemoryCandidates
        self.schemaVersion = schemaVersion
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.projectName = projectName
        self.resolutionNote = resolutionNote
        self.payload = payload
    }

    /// Sort order shared by every platform, so the inbox reads the same on a
    /// Mac, a phone, and a tablet: attention first, then recency.
    public static func rank(_ lhs: AIInboxMirrorRecord, _ rhs: AIInboxMirrorRecord) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.lastSeenAt > rhs.lastSeenAt
    }
}

/// Per-item user intent, written by whichever device the user acted on.
///
/// Kept in a sibling collection rather than on the item because the item is
/// Mac-owned and the state is user-owned — the same split the local schema uses
/// (`ai_inbox_items` vs `ai_inbox_item_state`). Any device may write it; the Mac
/// pulls it down so read/archive/snooze converge everywhere.
public struct AIInboxMirrorItemState: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var readAt: Date?
    public var archivedAt: Date?
    public var snoozedUntil: Date?
    public var feedback: String?
    public var updatedAt: Date
    /// Which device last wrote this, for last-writer-wins debugging.
    public var updatedByDeviceID: String?

    public init(
        id: String,
        readAt: Date? = nil,
        archivedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        feedback: String? = nil,
        updatedAt: Date = Date(),
        updatedByDeviceID: String? = nil
    ) {
        self.id = id
        self.readAt = readAt
        self.archivedAt = archivedAt
        self.snoozedUntil = snoozedUntil
        self.feedback = feedback
        self.updatedAt = updatedAt
        self.updatedByDeviceID = updatedByDeviceID
    }

    public func isSuppressed(now: Date = Date()) -> Bool {
        if archivedAt != nil { return true }
        if let snoozedUntil, snoozedUntil > now { return true }
        return false
    }

    public var isUnread: Bool { readAt == nil }
}
