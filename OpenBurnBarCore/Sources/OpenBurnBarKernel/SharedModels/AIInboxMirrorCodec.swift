import Foundation

// MARK: - AI Inbox cloud mirror codec
//
// Split out of AIInboxMirrorRecord.swift: the record and payload types are
// Foundation-only and live in OpenBurnBarInboxModels, while sealing needs
// CloudVaultCrypto, which lives here in Kernel. Keeping the codec in Kernel
// preserves that dependency direction instead of dragging the vault into a
// leaf target.

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
        guard let state = (data["state"] as? String).flatMap(BurnBarInboxItemState.init(rawValue:)),
              let firstSeenAt = dateValue(data["firstSeenAt"]),
              let lastSeenAt = dateValue(data["lastSeenAt"]) else {
            return nil
        }
        // An UNKNOWN kind degrades to `.system` rather than dropping the item.
        //
        // The Mac ships detectors ahead of the phones that read them: a Mac on a
        // newer build will publish a kind an older iOS or Android client has
        // never heard of. Dropping those items would make the inbox silently
        // incomplete on the older device — the exact failure mode this feature
        // exists to eliminate, and one with no error to notice.
        //
        // `.system` is the honest fallback: the title, priority, body, and
        // evidence are all still meaningful, only the icon and the category
        // label are generic. `state` is deliberately NOT lenient — an unknown
        // lifecycle state would put the row in the wrong list, which is worse
        // than omitting it.
        let kind = (data["kind"] as? String)
            .flatMap(BurnBarInboxItemKind.init(rawValue:)) ?? .system

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
