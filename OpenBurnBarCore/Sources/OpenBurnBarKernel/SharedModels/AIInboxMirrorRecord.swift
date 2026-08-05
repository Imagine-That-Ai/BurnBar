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
/// `aiInboxCloudPayload` coders at the bottom of this file). `kotlinx.serialization`
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

/// Encodes and decodes the mirror documents.
///
/// Structurally identical to `CLIAgentSessionCodec` on purpose: same sealing
/// helper, same AAD binding shape, same "refuse a future schema" rule. Matching
/// it means the existing `firestore.rules` predicates
/// (`validPathBoundSealedPayloadForUser`, `forbidsSealedPlaintextContentFields`)
/// apply unchanged, and the mobile clients reuse their existing vault plumbing.
public enum AIInboxMirrorCodec {
    public static let collection = "ai_inbox_items"
    public static let stateCollection = "ai_inbox_item_state"
    public static let sealedPayloadField = "sealedPayload"

    /// Every top-level key a mirror document may carry. The `firestore.rules`
    /// allowlist must match this exactly — a field added here without a rules
    /// update is silently rejected at write time.
    public static let documentKeys = [
        "id",
        "fingerprint",
        "kind",
        "priority",
        "state",
        "occurrenceCount",
        "firstSeenAt",
        "lastSeenAt",
        "resolvedAt",
        "modelProvenance",
        "hasMemoryCandidates",
        "schemaVersion",
        "contentSealed",
        "sealedSchemaVersion",
        "vaultKeyID",
        "sealedPayload",
        "updatedAt"
    ]

    public static let stateDocumentKeys = [
        "id",
        "readAt",
        "archivedAt",
        "snoozedUntil",
        "feedback",
        "updatedAt",
        "updatedByDeviceID"
    ]

    /// Feedback values the rules accept. Constrained so the field cannot become
    /// a free-text side channel.
    public static let allowedFeedbackValues = ["useful", "not_useful", "wrong"]

    // MARK: - Encoding

    public static func encodeSealed(
        _ record: AIInboxMirrorRecord,
        vaultKey: Data,
        vaultKeyID: String,
        uid: String,
        documentID: String,
        updatedAt: Date = Date()
    ) throws -> [String: Any] {
        let sealedPayload = AIInboxMirrorPayload(
            title: record.title,
            summaryMarkdown: record.summaryMarkdown,
            projectName: record.projectName,
            resolutionNote: record.resolutionNote,
            payload: record.payload
        )
        let encoded = try JSONEncoder.aiInboxCloudPayload.encode(sealedPayload)
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: documentID,
            field: sealedPayloadField
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            encoded,
            keyData: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )

        var dict: [String: Any] = [
            "id": documentID,
            "fingerprint": record.fingerprint,
            "kind": record.kind.rawValue,
            "priority": record.priority.rawValue,
            "state": record.state.rawValue,
            "occurrenceCount": record.occurrenceCount,
            "firstSeenAt": record.firstSeenAt,
            "lastSeenAt": record.lastSeenAt,
            "modelProvenance": record.modelProvenance,
            "hasMemoryCandidates": record.hasMemoryCandidates,
            "schemaVersion": record.schemaVersion,
            "sealedSchemaVersion": 2,
            "vaultKeyID": vaultKeyID,
            "contentSealed": true,
            "updatedAt": updatedAt,
            sealedPayloadField: CloudVaultCrypto.sealedPayloadDictionary(sealed)
        ]
        if let resolvedAt = record.resolvedAt {
            dict["resolvedAt"] = resolvedAt
        }
        return dict
    }

    // MARK: - Decoding

    /// Opens one mirror document. Returns `nil` — rather than a partial record —
    /// for anything unreadable: a future schema, a missing seal, a key that does
    /// not open it. A blank-bodied inbox row would be worse than an absent one.
    public static func decodeSealed(
        documentID: String,
        uid: String,
        data: [String: Any],
        vaultKey: Data
    ) -> AIInboxMirrorRecord? {
        guard let schemaVersion = intValue(data["schemaVersion"]),
              schemaVersion <= AIInboxMirrorRecord.currentSchemaVersion else {
            return nil
        }
        guard let envelope = CloudVaultCrypto.sealedPayload(from: data[sealedPayloadField]) else {
            return nil
        }
        guard let kind = (data["kind"] as? String).flatMap(BurnBarInboxItemKind.init(rawValue:)),
              let state = (data["state"] as? String).flatMap(BurnBarInboxItemState.init(rawValue:)),
              let firstSeenAt = dateValue(data["firstSeenAt"]),
              let lastSeenAt = dateValue(data["lastSeenAt"]) else {
            return nil
        }

        do {
            let aadContext = try CloudVaultAADContext(
                uid: uid,
                collection: collection,
                docID: documentID,
                field: sealedPayloadField
            )
            let opened = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            let payload = try JSONDecoder.aiInboxCloudPayload.decode(AIInboxMirrorPayload.self, from: opened)
            guard payload.title.isEmpty == false else { return nil }

            return AIInboxMirrorRecord(
                id: documentID,
                fingerprint: (data["fingerprint"] as? String) ?? documentID,
                kind: kind,
                priority: BurnBarInboxPriority(clamping: intValue(data["priority"]) ?? 3),
                state: state,
                occurrenceCount: max(1, intValue(data["occurrenceCount"]) ?? 1),
                firstSeenAt: firstSeenAt,
                lastSeenAt: lastSeenAt,
                resolvedAt: dateValue(data["resolvedAt"]),
                modelProvenance: (data["modelProvenance"] as? String) ?? "local-rules",
                hasMemoryCandidates: (data["hasMemoryCandidates"] as? Bool) ?? false,
                schemaVersion: schemaVersion,
                title: payload.title,
                summaryMarkdown: payload.summaryMarkdown,
                projectName: payload.projectName,
                resolutionNote: payload.resolutionNote,
                payload: payload.payload
            )
        } catch {
            return nil
        }
    }

    // MARK: - Item state

    public static func encodeItemState(
        _ state: AIInboxMirrorItemState,
        documentID: String
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": documentID,
            "updatedAt": state.updatedAt
        ]
        if let readAt = state.readAt { dict["readAt"] = readAt }
        if let archivedAt = state.archivedAt { dict["archivedAt"] = archivedAt }
        if let snoozedUntil = state.snoozedUntil { dict["snoozedUntil"] = snoozedUntil }
        if let feedback = state.feedback, allowedFeedbackValues.contains(feedback) {
            dict["feedback"] = feedback
        }
        if let deviceID = state.updatedByDeviceID, deviceID.isEmpty == false {
            dict["updatedByDeviceID"] = deviceID
        }
        return dict
    }

    public static func decodeItemState(
        documentID: String,
        data: [String: Any]
    ) -> AIInboxMirrorItemState? {
        guard let updatedAt = dateValue(data["updatedAt"]) else { return nil }
        let feedback = data["feedback"] as? String
        return AIInboxMirrorItemState(
            id: documentID,
            readAt: dateValue(data["readAt"]),
            archivedAt: dateValue(data["archivedAt"]),
            snoozedUntil: dateValue(data["snoozedUntil"]),
            feedback: allowedFeedbackValues.contains(feedback ?? "") ? feedback : nil,
            updatedAt: updatedAt,
            updatedByDeviceID: data["updatedByDeviceID"] as? String
        )
    }

    // MARK: - Value coercion
    //
    // Firestore hands back `Timestamp` on Apple platforms, `Date` from a local
    // encode, and `NSNumber` for integers. These accept all three without
    // importing FirebaseFirestore into the Kernel (which must stay Foundation-only
    // so Linux and the daemon can link it).

    static func dateValue(_ raw: Any?) -> Date? {
        if let date = raw as? Date { return date }
        // `Timestamp` is duck-typed via its `dateValue()` selector so the Kernel
        // does not need to import FirebaseFirestore.
        if let convertible = raw as? NSObject, convertible.responds(to: Selector(("dateValue"))) {
            return convertible.perform(Selector(("dateValue")))?.takeUnretainedValue() as? Date
        }
        if let seconds = raw as? Double { return Date(timeIntervalSince1970: seconds) }
        if let string = raw as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}

// The `cli_sessions` codec keeps its equivalents fileprivate to its own file, so
// these are declared here rather than shared. The settings must stay identical:
// ISO-8601 dates and sorted keys, so a sealed payload is byte-reproducible and
// therefore diffable and testable.
private extension JSONEncoder {
    static var aiInboxCloudPayload: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var aiInboxCloudPayload: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
