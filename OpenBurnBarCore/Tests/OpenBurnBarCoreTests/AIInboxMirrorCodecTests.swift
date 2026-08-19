import XCTest
import Foundation
@testable import OpenBurnBarKernel

/// The cross-platform contract for the AI Inbox cloud mirror.
///
/// These tests exist because a drift here fails SILENTLY: if the Mac writes a
/// field the phone does not read (or writes an enum value the phone cannot
/// parse), the mobile inbox shows an empty list with no error. There is no
/// crash to notice and no log to read — the user just concludes the feature
/// does not work.
///
/// So this suite pins three things:
///   1. the exact top-level field names (which must equal the `firestore.rules`
///      allowlist, or every write is rejected),
///   2. the exact raw enum values (which the Kotlin and rules copies mirror),
///   3. that unreadable documents produce `nil` rather than a half-built row.
final class AIInboxMirrorCodecTests: XCTestCase {
    private let uid = "user-123"
    private let documentID = "inb_abc123"
    private lazy var vaultKey = Data(repeating: 0x2B, count: 32)
    /// `CloudVaultCrypto.openPayload` verifies the envelope's key id against one
    /// DERIVED from the key material, so this must be the real derivation rather
    /// than an arbitrary string.
    private lazy var vaultKeyID = (try? CloudVaultCrypto.vaultKeyID(for: vaultKey)) ?? ""

    // MARK: - Round trip

    func test_sealedRoundTripPreservesEveryField() throws {
        let firstSeen = Date(timeIntervalSince1970: 1_754_300_000)
        let lastSeen = firstSeen.addingTimeInterval(3_600)
        let record = AIInboxMirrorRecord(
            id: documentID,
            fingerprint: "ci_waste:9f2c",
            kind: .ciWaste,
            priority: .p1,
            state: .updated,
            occurrenceCount: 4,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen,
            resolvedAt: nil,
            modelProvenance: "deepseek:deepseek-chat+openai:gpt-5.6-luna",
            hasMemoryCandidates: true,
            title: "95% of nightly-matrix runs are wasted",
            summaryMarkdown: "**38 of 40 runs** ended in failure, burning ~304 minutes.",
            projectName: "Ajnunezg/BurnBar",
            resolutionNote: nil,
            payload: Self.richPayload()
        )

        let encoded = try AIInboxMirrorCodec.encodeSealed(
            record,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.fingerprint, record.fingerprint)
        XCTAssertEqual(decoded.kind, .ciWaste)
        XCTAssertEqual(decoded.priority, .p1)
        XCTAssertEqual(decoded.state, .updated)
        XCTAssertEqual(decoded.occurrenceCount, 4)
        XCTAssertEqual(decoded.firstSeenAt.timeIntervalSince1970, firstSeen.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.lastSeenAt.timeIntervalSince1970, lastSeen.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.modelProvenance, record.modelProvenance)
        XCTAssertTrue(decoded.hasMemoryCandidates)

        // The sealed half.
        XCTAssertEqual(decoded.title, record.title)
        XCTAssertEqual(decoded.summaryMarkdown, record.summaryMarkdown)
        XCTAssertEqual(decoded.projectName, "Ajnunezg/BurnBar")
        XCTAssertEqual(decoded.payload.evidence.count, 2)
        XCTAssertEqual(decoded.payload.evidence.first?.kind, .workflowRun)
        XCTAssertEqual(decoded.payload.evidence.first?.url, "https://github.com/o/r/actions/runs/1")
        XCTAssertEqual(decoded.payload.memoryCandidates.first?.kind, "gotcha")
        XCTAssertEqual(decoded.payload.actions.first?.kind, .openURL)
        XCTAssertEqual(decoded.payload.metrics["waste_rate"], "0.950")
        XCTAssertEqual(decoded.payload.verification?.verdict, .deterministic)
    }

    /// The whole point of sealing: the body must not be legible in the document.
    func test_sealedDocumentLeaksNoContent() throws {
        let secret = "The auth middleware refactor never landed"
        let record = Self.makeRecord(title: secret, summaryMarkdown: "Body mentioning \(secret).")

        let encoded = try AIInboxMirrorCodec.encodeSealed(
            record,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )

        XCTAssertNil(encoded["title"], "Title must never appear as a plaintext field")
        XCTAssertNil(encoded["summaryMarkdown"])
        XCTAssertNil(encoded["projectName"])
        XCTAssertNil(encoded["payload"])

        let rendered = String(describing: encoded)
        XCTAssertFalse(rendered.contains(secret), "Sealed content leaked into the document")
        XCTAssertEqual(encoded["contentSealed"] as? Bool, true)
        XCTAssertEqual(encoded["sealedSchemaVersion"] as? Int, 2)
    }

    // MARK: - The rules allowlist

    /// `firestore.rules` uses `keys().hasOnly([...])`. If the encoder emits a key
    /// the allowlist omits, EVERY write is rejected — so the encoder's output
    /// must be a subset of the declared key list.
    func test_encodedKeysAreSubsetOfDeclaredAllowlist() throws {
        let allowed = Set(AIInboxMirrorCodec.documentKeys)

        // Minimal record.
        let minimal = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        XCTAssertTrue(
            Set(minimal.keys).isSubset(of: allowed),
            "Unlisted keys: \(Set(minimal.keys).subtracting(allowed))"
        )

        // Fully-populated record — exercises every optional branch.
        var full = Self.makeRecord()
        full.resolvedAt = Date()
        full.resolutionNote = "PR #12 has been merged."
        let maximal = try AIInboxMirrorCodec.encodeSealed(
            full,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        XCTAssertTrue(
            Set(maximal.keys).isSubset(of: allowed),
            "Unlisted keys: \(Set(maximal.keys).subtracting(allowed))"
        )
    }

    /// Pins the wire names. Renaming a field is a breaking change across three
    /// platforms plus the rules file, so it should require deleting an assertion
    /// here rather than happening silently.
    func test_documentKeysAreStable() {
        XCTAssertEqual(
            AIInboxMirrorCodec.documentKeys.sorted(),
            [
                "contentSealed", "fingerprint", "firstSeenAt", "hasMemoryCandidates", "id",
                "kind", "lastSeenAt", "modelProvenance", "occurrenceCount", "priority",
                "resolvedAt", "schemaVersion", "sealedPayload", "sealedSchemaVersion",
                "state", "updatedAt", "vaultKeyID"
            ]
        )
        XCTAssertEqual(
            AIInboxMirrorCodec.stateDocumentKeys.sorted(),
            ["archivedAt", "feedback", "id", "readAt", "snoozedUntil", "updatedAt", "updatedByDeviceID"]
        )
        XCTAssertEqual(AIInboxMirrorCodec.collection, "ai_inbox_items")
        XCTAssertEqual(AIInboxMirrorCodec.stateCollection, "ai_inbox_item_state")
    }

    /// The Kotlin enums and the rules `in [...]` lists are hand-mirrored copies
    /// of these strings.
    func test_rawEnumValuesAreStableAcrossPlatforms() {
        XCTAssertEqual(
            BurnBarInboxItemKind.allCases.map(\.rawValue).sorted(),
            [
                "brief", "budget", "ci_waste", "cost_anomaly", "index_health",
                "promised_not_landed", "stuck_pr", "system", "uncommitted_work"
            ]
        )
        XCTAssertEqual(
            BurnBarInboxItemState.allCases.map(\.rawValue).sorted(),
            ["expired", "new", "resolved", "updated"]
        )
        XCTAssertEqual(BurnBarInboxPriority.allCases.map(\.rawValue).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(AIInboxMirrorCodec.allowedFeedbackValues, ["useful", "not_useful", "wrong"])
    }

    // MARK: - Refusing unreadable documents

    func test_decodeRefusesFutureSchemaVersion() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded["schemaVersion"] = AIInboxMirrorRecord.currentSchemaVersion + 1

        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "A document from a newer client must be skipped, not half-read"
        )
    }

    func test_decodeRefusesWrongVaultKey() throws {
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: Data(repeating: 0x99, count: 32)
            )
        )
    }

    /// The AAD binds the seal to (uid, collection, docID, field). Replaying a
    /// document under a different id must not open — otherwise one user's item
    /// could be relocated to another document and still decrypt.
    func test_decodeRefusesDocumentReplayedUnderDifferentID() throws {
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(
                documentID: "inb_someone_elses",
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "AAD must bind the seal to its document id"
        )
    }

    func test_decodeRefusesDocumentReplayedUnderDifferentUID() throws {
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: "another-user",
                data: encoded,
                vaultKey: vaultKey
            )
        )
    }

    /// Forward compatibility: a Mac running a newer build publishes detector
    /// kinds an older phone has never heard of. Those items must still appear —
    /// dropping them would make the inbox silently incomplete on the older
    /// device, with nothing to indicate anything was missing.
    func test_unknownKindDegradesToSystemRatherThanDroppingTheItem() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(title: "A detector from the future"),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded["kind"] = "some_future_detector"

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "An unrecognized kind must not drop the item"
        )
        XCTAssertEqual(decoded.kind, .system, "Unknown kinds read as the generic notice category")
        XCTAssertEqual(decoded.title, "A detector from the future", "Everything else survives intact")
        XCTAssertEqual(decoded.priority, .p1)
        XCTAssertFalse(decoded.payload.evidence.isEmpty)
    }

    /// Absent and unrecognized are the same situation from this build's point of
    /// view, so they must not diverge. (Kotlin asserts the same symmetry.)
    func test_missingKindDegradesExactlyLikeAnUnknownOne() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded.removeValue(forKey: "kind")

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )
        XCTAssertEqual(decoded.kind, .system)
    }

    /// `state`, unlike `kind`, stays strict: an unrecognized lifecycle state
    /// would file the row under the wrong filter — worse than omitting it.
    func test_unknownStateStillDropsTheItem() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded["state"] = "some_future_state"

        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )
    }

    func test_decodeRefusesMissingSeal() {
        let data: [String: Any] = [
            "id": documentID,
            "fingerprint": "f",
            "kind": "ci_waste",
            "priority": 1,
            "state": "new",
            "firstSeenAt": Date(),
            "lastSeenAt": Date(),
            "schemaVersion": 1
        ]
        XCTAssertNil(
            AIInboxMirrorCodec.decodeSealed(documentID: documentID, uid: uid, data: data, vaultKey: vaultKey)
        )
    }

    // MARK: - Value coercion
    //
    // Firestore returns `Timestamp` on Apple platforms and `NSNumber` for ints;
    // a locally-encoded dictionary returns `Date` and `Int`. Both must decode.

    func test_decodeAcceptsNumericAndStringCoercions() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded["priority"] = NSNumber(value: 2)
        encoded["occurrenceCount"] = NSNumber(value: 7)
        encoded["schemaVersion"] = NSNumber(value: 1)

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )
        XCTAssertEqual(decoded.priority, .p2)
        XCTAssertEqual(decoded.occurrenceCount, 7)
    }

    func test_priorityOutOfRangeClampsRatherThanFailing() throws {
        var encoded = try AIInboxMirrorCodec.encodeSealed(
            Self.makeRecord(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: documentID
        )
        encoded["priority"] = 99

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )
        XCTAssertEqual(decoded.priority, .p4, "An out-of-range priority degrades to background, not a dropped item")
    }

    // MARK: - Item state

    func test_itemStateRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_754_400_000)
        let state = AIInboxMirrorItemState(
            id: documentID,
            readAt: now,
            archivedAt: nil,
            snoozedUntil: now.addingTimeInterval(3_600),
            feedback: "useful",
            updatedAt: now,
            updatedByDeviceID: "iphone-1"
        )
        let encoded = AIInboxMirrorCodec.encodeItemState(state, documentID: documentID)
        XCTAssertTrue(Set(encoded.keys).isSubset(of: Set(AIInboxMirrorCodec.stateDocumentKeys)))

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeItemState(documentID: documentID, data: encoded)
        )
        XCTAssertEqual(try XCTUnwrap(decoded.readAt).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.feedback, "useful")
        XCTAssertEqual(decoded.updatedByDeviceID, "iphone-1")
        XCTAssertTrue(decoded.isSuppressed(now: now), "A future snooze suppresses the row")
        XCTAssertFalse(decoded.isUnread)
    }

    /// `feedback` is a constrained vocabulary, not free text — otherwise it
    /// becomes an unreviewed channel for arbitrary strings into the user's cloud.
    func test_itemStateRejectsArbitraryFeedbackValue() throws {
        let state = AIInboxMirrorItemState(id: documentID, feedback: "<script>alert(1)</script>")
        let encoded = AIInboxMirrorCodec.encodeItemState(state, documentID: documentID)
        XCTAssertNil(encoded["feedback"])

        // Unwrapped, not optional-chained: the point is that the document still
        // decodes and only the unlisted feedback value is dropped. A nil decode
        // would satisfy an optional-chained assertion while proving nothing.
        let decoded = try XCTUnwrap(AIInboxMirrorCodec.decodeItemState(
            documentID: documentID,
            data: ["id": documentID, "updatedAt": Date(), "feedback": "totally-made-up"]
        ))
        XCTAssertNil(decoded.feedback)
    }

    func test_expiredSnoozeDoesNotSuppress() {
        let now = Date()
        let state = AIInboxMirrorItemState(
            id: documentID,
            snoozedUntil: now.addingTimeInterval(-60),
            updatedAt: now
        )
        XCTAssertFalse(state.isSuppressed(now: now))
    }

    // MARK: - Ranking

    /// Every platform sorts through `AIInboxMirrorRecord.rank`, so the inbox
    /// reads identically on a Mac, a phone, and a tablet.
    func test_rankPutsPriorityBeforeRecency() {
        let now = Date()
        let urgentButOld = Self.makeRecord(priority: .p1, lastSeenAt: now.addingTimeInterval(-86_400))
        let quietButNew = Self.makeRecord(priority: .p4, lastSeenAt: now)

        XCTAssertTrue(AIInboxMirrorRecord.rank(urgentButOld, quietButNew))
        XCTAssertFalse(AIInboxMirrorRecord.rank(quietButNew, urgentButOld))

        let newer = Self.makeRecord(priority: .p2, lastSeenAt: now)
        let older = Self.makeRecord(priority: .p2, lastSeenAt: now.addingTimeInterval(-600))
        XCTAssertTrue(AIInboxMirrorRecord.rank(newer, older), "Within a band, recency wins")
    }

    // MARK: - Fixtures

    private static func makeRecord(
        title: String = "95% of nightly-matrix runs are wasted",
        summaryMarkdown: String = "**38 of 40 runs** failed.",
        priority: BurnBarInboxPriority = .p1,
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_754_303_600)
    ) -> AIInboxMirrorRecord {
        AIInboxMirrorRecord(
            id: "inb_abc123",
            fingerprint: "ci_waste:9f2c",
            kind: .ciWaste,
            priority: priority,
            state: .new,
            occurrenceCount: 1,
            firstSeenAt: Date(timeIntervalSince1970: 1_754_300_000),
            lastSeenAt: lastSeenAt,
            title: title,
            summaryMarkdown: summaryMarkdown,
            projectName: "Ajnunezg/BurnBar",
            payload: richPayload()
        )
    }

    private static func richPayload() -> BurnBarInboxItemPayload {
        BurnBarInboxItemPayload(
            evidence: [
                BurnBarInboxEvidence(
                    id: "run:o/r#1",
                    kind: .workflowRun,
                    label: "nightly · failure",
                    detail: "abc123 on main · 8m",
                    url: "https://github.com/o/r/actions/runs/1",
                    occurredAt: Date(timeIntervalSince1970: 1_754_301_000)
                ),
                BurnBarInboxEvidence(
                    id: "conv:c1:12",
                    kind: .conversation,
                    label: "Auth middleware refactor",
                    detail: "Claude Code · 12 messages",
                    url: "openburnbar://sessions/c1"
                )
            ],
            memoryCandidates: [
                BurnBarInboxMemoryCandidate(
                    id: "mem_1",
                    text: "The nightly matrix workflow double-triggers on push and PR.",
                    kind: "gotcha",
                    confidence: 0.8,
                    citationConversationIDs: ["c1"]
                )
            ],
            actions: [
                BurnBarInboxAction(
                    id: "open-runs",
                    kind: .openURL,
                    title: "View workflow runs",
                    value: "https://github.com/o/r/actions",
                    isPrimary: true
                )
            ],
            metrics: ["waste_rate": "0.950", "wasted_minutes": "304.0"],
            verification: BurnBarInboxVerification(
                verdict: .deterministic,
                reason: "Computed from 40 completed workflow runs.",
                checkedAt: Date(timeIntervalSince1970: 1_754_303_600)
            )
        )
    }
}
