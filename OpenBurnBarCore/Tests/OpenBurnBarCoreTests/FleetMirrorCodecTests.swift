import OpenBurnBarKernel
import XCTest

/// The cross-platform contract for the fleet cloud mirror.
///
/// Same rationale as `AIInboxMirrorCodecTests`: a drift here fails SILENTLY —
/// if the Mac writes a field the phone does not read (or a key the
/// `firestore.rules` allowlist omits), the mobile fleet board shows nothing
/// with no error anywhere. So this suite pins the exact top-level field names,
/// the byte-determinism the publisher's watermark depends on, and that
/// unreadable documents produce `nil` rather than a fabricated board.
final class FleetMirrorCodecTests: XCTestCase {
    private let uid = "user-123"
    private lazy var vaultKey = Data(repeating: 0x2B, count: 32)
    /// `CloudVaultCrypto.openPayload` verifies the envelope's key id against one
    /// DERIVED from the key material, so this must be the real derivation rather
    /// than an arbitrary string.
    private lazy var vaultKeyID = (try? CloudVaultCrypto.vaultKeyID(for: vaultKey)) ?? ""

    // MARK: - Round trip

    func test_sealedRoundTripPreservesTheSnapshot() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_755_600_000)
        let updatedAt = generatedAt.addingTimeInterval(4)
        let snapshot = Self.makeSnapshot(generatedAt: generatedAt)

        let encoded = try FleetMirrorCodec.encodeSealed(
            snapshot,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            updatedAt: updatedAt
        )
        let decoded = try XCTUnwrap(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )

        // The fleet contracts pin `Hashable` equality, so one assertion covers
        // every agent row, sensor state, and orchestrator field.
        XCTAssertEqual(decoded.snapshot, snapshot)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970, generatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// The publisher's change watermark hashes `snapshotJSONData`; a
    /// nondeterministic encoding would make every cycle look like a change and
    /// defeat the gate entirely.
    func test_snapshotJSONDataIsDeterministic() throws {
        let snapshot = Self.makeSnapshot()
        XCTAssertEqual(
            try FleetMirrorCodec.snapshotJSONData(snapshot),
            try FleetMirrorCodec.snapshotJSONData(snapshot)
        )
    }

    /// The whole point of sealing: nothing about the fleet may be legible in
    /// the document. Unlike the inbox there is no plaintext routing metadata at
    /// all — the envelope is only versions and timestamps.
    func test_sealedDocumentLeaksNoContent() throws {
        let secretTask = "Rotate the leaked deploy credential"
        let secretRepo = "/Users/albertonunez/Developer/AgentLens"
        let snapshot = Self.makeSnapshot(currentTask: secretTask, projectName: secretRepo)

        let encoded = try FleetMirrorCodec.encodeSealed(
            snapshot,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid
        )

        let rendered = String(describing: encoded)
        XCTAssertFalse(rendered.contains(secretTask), "Sealed content leaked into the document")
        XCTAssertFalse(rendered.contains(secretRepo), "Sealed content leaked into the document")
        XCTAssertFalse(rendered.contains("claude-code"), "Agent identities must not ride in plaintext")
        XCTAssertEqual(encoded["contentSealed"] as? Bool, true)
        XCTAssertEqual(encoded["sealedSchemaVersion"] as? Int, 2)
    }

    // MARK: - The rules allowlist

    /// `firestore.rules` uses `keys().hasOnly([...])`. Every envelope field is
    /// unconditional, so the encoder's output must EQUAL the declared list —
    /// a key added on one side without the other rejects every write.
    func test_encodedKeysEqualDeclaredAllowlist() throws {
        let encoded = try FleetMirrorCodec.encodeSealed(
            Self.makeSnapshot(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid
        )
        XCTAssertEqual(Set(encoded.keys), Set(FleetMirrorCodec.documentKeys))
    }

    /// Pins the wire names and the collection/document path. Renaming any of
    /// these is a breaking change across three platforms plus the rules file,
    /// so it should require deleting an assertion here rather than happening
    /// silently.
    func test_documentKeysAndPathAreStable() {
        XCTAssertEqual(
            FleetMirrorCodec.documentKeys.sorted(),
            [
                "contentSealed", "generatedAt", "schemaVersion",
                "sealedPayload", "sealedSchemaVersion", "updatedAt", "vaultKeyID"
            ]
        )
        XCTAssertEqual(FleetMirrorCodec.collection, "fleet_snapshot")
        XCTAssertEqual(FleetMirrorCodec.documentID, "current")
        XCTAssertEqual(FleetMirrorCodec.currentSchemaVersion, 1)
    }

    // MARK: - Refusing unreadable documents

    func test_decodeRefusesFutureEnvelopeSchemaVersion() throws {
        var encoded = try encodedFixture()
        encoded["schemaVersion"] = FleetMirrorCodec.currentSchemaVersion + 1

        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "A document from a newer client must be skipped, not half-read"
        )
    }

    func test_decodeRefusesWrongVaultKey() throws {
        let encoded = try encodedFixture()
        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: Data(repeating: 0x99, count: 32)
            )
        )
    }

    /// The AAD binds the seal to (uid, collection, docID, field). Replaying the
    /// document under a different id or uid must not open.
    func test_decodeRefusesDocumentReplayedUnderDifferentID() throws {
        let encoded = try encodedFixture()
        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: "someone_elses_doc",
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "AAD must bind the seal to its document id"
        )
    }

    func test_decodeRefusesDocumentReplayedUnderDifferentUID() throws {
        let encoded = try encodedFixture()
        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: "another-user",
                data: encoded,
                vaultKey: vaultKey
            )
        )
    }

    func test_decodeRefusesMissingSeal() {
        let data: [String: Any] = [
            "schemaVersion": 1,
            "updatedAt": Date(),
            "generatedAt": Date()
        ]
        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: data,
                vaultKey: vaultKey
            )
        )
    }

    func test_decodeRefusesMissingEnvelopeDates() throws {
        var encoded = try encodedFixture()
        encoded.removeValue(forKey: "updatedAt")
        XCTAssertNil(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            ),
            "Without updatedAt a client cannot render staleness honestly, so the document is unreadable"
        )
    }

    // MARK: - Fixtures

    private func encodedFixture() throws -> [String: Any] {
        try FleetMirrorCodec.encodeSealed(
            Self.makeSnapshot(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid
        )
    }

    private static func makeSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_755_600_000),
        currentTask: String? = "Refactor probe layer",
        projectName: String? = "/Users/albertonunez/Developer/AgentLens"
    ) -> BurnBarFleetSnapshot {
        let running = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess,
            currentTask: currentTask,
            projectName: projectName,
            model: "claude-sonnet-4-5",
            lastActivityAt: generatedAt,
            process: BurnBarFleetProcessInfo(
                pid: 19_457,
                cpuPercent: 3.2,
                memoryBytes: 1_024_000_000,
                startedAt: generatedAt
            ),
            signals: [
                BurnBarFleetSignalSource(
                    kind: "session-registry",
                    path: "/Users/albertonunez/.claude/sessions/19457.json",
                    detail: "updatedAt fresh"
                )
            ]
        )
        let idle = BurnBarFleetAgent(
            id: .kimi,
            displayName: "Kimi",
            status: .unknown,
            confidence: .unsupported,
            note: "no live signal defined"
        )
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: 15,
            machine: BurnBarMachineStatus(
                cpuPercent: 12.5,
                memoryUsedBytes: 8_000_000_000,
                memoryTotalBytes: 48_000_000_000,
                loadAverage: [1.2, 1.0, 0.8],
                diskFreeBytes: 500_000_000_000,
                thermal: .unavailable(reason: "pmset thermlog empty"),
                power: .available(value: 0.42)
            ),
            agents: [running, idle],
            repos: projectName.map {
                [BurnBarFleetRepoGroup(projectName: $0, agents: [.claudeCode])]
            } ?? [],
            runningCount: 1,
            countsByAgent: ["claude-code": 1, "kimi": 0],
            orchestrator: BurnBarOrchestratorState(
                designation: .agent(id: .claudeCode, sessionRef: .present("sess-1")),
                setAt: generatedAt,
                pendingDirectives: 2
            ),
            probeHealth: [
                BurnBarFleetProbeHealth(
                    agent: .claudeCode,
                    state: .ok,
                    rootPath: "/Users/albertonunez/.claude",
                    checkedAt: generatedAt
                ),
                BurnBarFleetProbeHealth(
                    agent: .kimi,
                    state: .degraded(reason: "root missing"),
                    rootPath: "/Users/albertonunez/.kimi",
                    checkedAt: generatedAt
                )
            ],
            persistenceHealth: .ok
        )
    }
}
