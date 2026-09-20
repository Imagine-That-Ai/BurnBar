import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// B8, app half: `ControlPlaneStore.memoryTimeline` reads the APP's own
/// hash-chained `memory_audit` ledger — not the engine's revision bodies, which
/// live in a store no Swift process reads.
///
/// The distinctions these tests exist to hold:
///   * `seq` order is the history's order, whatever order rows come back in.
///   * `lastHelpedSource` can only ever be `"history"` here. The engine also
///     serves `"recall_serve"`, from a table the app does not keep.
///   * "nothing knows that id" (`not_found`) is not "known, nothing happened"
///     (`ok` with no revisions).
///   * revision contents were never retained, and the record says so rather
///     than letting nil `before`/`after` read as "unchanged".
///   * a database that cannot answer is a FAILURE, never an empty timeline.
final class ControlPlaneStoreMemoryTimelineTests: XCTestCase {

    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    /// Inserts an audit row with an explicit `seq` so the read's ORDER BY is
    /// tested rather than SQLite's insertion order.
    private func insertAuditEvent(
        _ queue: DatabaseQueue,
        seq: Int,
        subjectID: String,
        action: String,
        ts: String,
        actor: String = "app",
        labels: [String] = [],
        domain: String = "memory"
    ) async throws {
        let labelsJSON = String(
            data: try JSONSerialization.data(withJSONObject: labels.sorted(), options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "[]"
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_audit
                    (seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
                VALUES (?, ?, ?, ?, ?, 'proj_fixture', ?, ?, NULL, ?)
                """,
                arguments: [seq, ts, actor, action, domain, subjectID, labelsJSON, "hash-\(seq)"]
            )
        }
    }

    private func insertAuthorityRow(
        _ queue: DatabaseQueue,
        id: String,
        validFrom: String = "2026-09-01T00:00:00.000Z",
        validTo: String? = nil,
        supersededBy: String? = nil
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories
                    (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json,
                     source_path, valid_from, valid_to, superseded_by, created_at, updated_at)
                VALUES (?, 'proj_fixture', 'fact', 'project', 0.7, 'ref', 'redacted', '[]',
                        NULL, ?, ?, ?, ?, ?)
                """,
                arguments: [id, validFrom, validTo, supersededBy, validFrom, validFrom]
            )
        }
    }

    // MARK: - Ordering

    func test_the_timeline_orders_audit_events_by_seq_ascending() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_ordered")
        // Inserted out of order on purpose.
        try await insertAuditEvent(queue, seq: 3, subjectID: "mem_ordered", action: "memory.approve", ts: "2026-09-03T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_ordered", action: "memory.add", ts: "2026-09-01T00:00:00.000Z", labels: ["fact"])
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_ordered", action: "memory.update", ts: "2026-09-02T00:00:00.000Z")
        // A different memory's events must not leak into this timeline.
        try await insertAuditEvent(queue, seq: 4, subjectID: "mem_other", action: "memory.add", ts: "2026-09-04T00:00:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_ordered")

        XCTAssertEqual(record.status, MemoryTimelineRecord.statusOK)
        XCTAssertEqual(record.memoryID, "mem_ordered")
        XCTAssertEqual(record.revisions.map(\.seq), [1, 2, 3])
        XCTAssertEqual(record.revisions.map(\.event), ["memory.add", "memory.update", "memory.approve"])
        XCTAssertEqual(record.revisions.map(\.ts), [
            "2026-09-01T00:00:00.000Z",
            "2026-09-02T00:00:00.000Z",
            "2026-09-03T00:00:00.000Z"
        ])
        XCTAssertEqual(record.revisions.first?.meta["labels"], "fact")
        XCTAssertEqual(record.source, MemoryTimelineSource.appAudit)
        XCTAssertEqual(record.validFrom, "2026-09-01T00:00:00.000Z")
    }

    // MARK: - Last helped

    func test_last_helped_source_is_history_and_never_recall_serve() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_helped")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_helped", action: "memory.add", ts: "2026-09-01T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_helped", action: "memory.approve", ts: "2026-09-04T09:30:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_helped")

        XCTAssertEqual(record.lastHelpedAt, "2026-09-04T09:30:00.000Z", "the latest recorded event, not the first")
        XCTAssertEqual(record.lastHelpedSource, MemoryTimelineRecord.lastHelpedSourceHistory)
        XCTAssertNotEqual(
            record.lastHelpedSource,
            "recall_serve",
            "the app keeps no recall-serve ledger, so it can never claim that source"
        )

        // A known memory nothing has touched reports no last-helped at all
        // rather than inventing one.
        try await insertAuthorityRow(queue, id: "mem_untouched")
        let untouched = try await store.memoryTimeline(memoryID: "mem_untouched")
        XCTAssertEqual(untouched.status, MemoryTimelineRecord.statusOK)
        XCTAssertTrue(untouched.revisions.isEmpty)
        XCTAssertNil(untouched.lastHelpedAt)
        XCTAssertNil(untouched.lastHelpedSource)
    }

    // MARK: - not_found vs empty ok

    func test_an_unknown_memory_id_is_not_found_rather_than_an_empty_ok() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_known")

        let unknown = try await store.memoryTimeline(memoryID: "mem_never_existed")
        XCTAssertEqual(unknown.status, MemoryTimelineRecord.statusNotFound)
        XCTAssertTrue(unknown.revisions.isEmpty)
        XCTAssertNil(unknown.validFrom)

        let known = try await store.memoryTimeline(memoryID: "mem_known")
        XCTAssertEqual(known.status, MemoryTimelineRecord.statusOK)
        XCTAssertTrue(known.revisions.isEmpty)
        XCTAssertNotEqual(
            known.status,
            unknown.status,
            "'known but untouched' and 'no such memory' are different answers"
        )
    }

    // MARK: - Revision bodies

    func test_revision_bodies_are_absent_and_the_record_says_so() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_bodies")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_bodies", action: "memory.add", ts: "2026-09-01T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_bodies", action: "memory.update", ts: "2026-09-02T00:00:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_bodies")

        XCTAssertEqual(record.revisions.count, 2)
        XCTAssertTrue(record.revisions.allSatisfy { $0.before == nil && $0.after == nil })
        XCTAssertFalse(
            record.revisionBodiesRetained,
            "the audit ledger never retained revision contents, and the record must say so"
        )
        XCTAssertTrue(
            record.revisions.allSatisfy { $0.writerDevice == nil },
            "memory_audit records no per-event device — every row was written by this device"
        )
    }

    // MARK: - Table absent is a failure

    func test_a_missing_audit_table_is_a_failure_not_an_empty_timeline() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_no_ledger")
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE memory_audit")
        }

        do {
            let record = try await store.memoryTimeline(memoryID: "mem_no_ledger")
            XCTFail("a database that cannot answer must throw, got \(record.status)")
        } catch let error as MemoryTimelineError {
            guard case .historyUnavailable = error else {
                XCTFail("unexpected timeline error \(error)")
                return
            }
            XCTAssertEqual(
                error.errorDescription?.hasPrefix("History unavailable"),
                true,
                "the member is told the history could not be read, not that there is none"
            )
        }
    }

    // MARK: - Inbound writer device

    func test_a_synced_memory_names_the_device_it_arrived_from() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_synced")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_synced", action: "memory.merge", ts: "2026-09-01T00:00:00.000Z")
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_synced', 'proj_fixture', 'eng_mem_1', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-1', 'user-1', 'eng_mem_1', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"memoryID":"eng_mem_1","writerDevice":"studio-ultra"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let record = try await store.memoryTimeline(memoryID: "mem_synced", userID: "user-1")
        XCTAssertEqual(record.writerDevice, "studio-ultra")

        // A memory that never came down from another device names none.
        try await insertAuthorityRow(queue, id: "mem_local")
        let local = try await store.memoryTimeline(memoryID: "mem_local", userID: "user-1")
        XCTAssertNil(local.writerDevice)
    }

    /// PR3 Cursor ruling, T2 (HIGH): a TEAM inbox row is never read as the
    /// arrival record of a PERSONAL memory.
    ///
    /// The join is on `engine_memory_id` alone, and a team row is parked under
    /// the engine id its payload SEALS — a value chosen by whoever sealed the
    /// document, and every uploaded team document publishes one. So a member of
    /// a team could name a teammate's private engine id, and their sealed
    /// `writerDevice` / `teamID` / `authorUID` would be reported here as facts
    /// about a memory the team never touched, to the UI and to the calling
    /// model alike.
    func test_a_team_inbox_row_never_names_the_device_of_a_personal_memory() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_private")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_private",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_private', 'proj_fixture', 'eng_mem_victim', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            // A TEAM row, parked under the victim's engine id, and NEWER than
            // the personal one below so `ORDER BY remote_updated_at DESC` would
            // have preferred it.
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, 'user-1', 'eng_mem_victim', ?, ?, ?, NULL)
                """,
                arguments: [
                    TeamMemoryPullService.inboxDocID(
                        teamID: "team_0123456789abcdef",
                        localUserID: "user-1",
                        documentID: String(repeating: "a", count: 64)
                    ),
                    #"""
                    {"memoryID":"eng_mem_victim","writerDevice":"attacker-laptop",\#
                    "teamID":"team_0123456789abcdef","authorUID":"uid-attacker",\#
                    "projectID":"proj_fixture","engineScope":"project","bodyHash":"hash"}
                    """#,
                    "2026-09-09T00:00:00.000Z",
                    "2026-09-09T00:01:00.000Z"
                ]
            )
        }

        let poisoned = try await store.memoryTimeline(memoryID: "mem_private", userID: "user-1")
        XCTAssertNil(poisoned.writerDevice, "a team row must never name a personal memory's arrival device")
        // ...AND IT NAMES NO TEAM EITHER (PR 4). The badge lift is keyed on the
        // id the engine DERIVES — over this payload's canonicalised
        // `(teamID, projectID, engineScope)` and the CANONICAL hash of the
        // LOCAL body, never the `bodyHash` the payload advertises — and what it
        // derives is a team-namespaced id that is not `eng_mem_victim`. A
        // payload cannot reach a chosen personal row without a SHA-256
        // preimage, and personal ids are random rather than derived.
        XCTAssertNil(poisoned.teamID, "a forged team row must not badge a personal memory")
        XCTAssertNil(poisoned.authorUID)

        // The member's OWN inbox row for the same memory is still read, so the
        // exclusion is about provenance and not about the join being disabled.
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-personal', 'user-1', 'eng_mem_victim', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"memoryID":"eng_mem_victim","writerDevice":"my-own-macbook"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }
        let honest = try await store.memoryTimeline(memoryID: "mem_private", userID: "user-1")
        XCTAssertEqual(honest.writerDevice, "my-own-macbook")
    }

    // MARK: - Inbound team provenance (memory program D16 / P22, PR 4)

    /// The badge's two fields are lifted from the parked team document — keyed
    /// on the id the ENGINE DERIVES, not the one the payload seals.
    ///
    /// PR 3's Cursor ruling T2 made the sealed `memoryID` non-authoritative:
    /// `memory_engine/_namespaces.py::_team_local_memory_id` lands a team
    /// document under `sha256("team|<teamID>|<convergence identity>")`, and the
    /// `writerDevice` join therefore excludes team rows outright — a team row's
    /// `engine_memory_id` column is the attacker-choosable sealed value and is a
    /// key to nothing local. So the team lift does its own lookup and its own
    /// derivation, over the payload's OWN `(teamID, projectID, engineScope,
    /// bodyHash)`.
    func test_a_team_fact_names_its_team_and_contributor() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_team")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_team",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        // The hash the ENGINE would have keyed this row on: recomputed from the
        // body this device holds, lowercased, never the payload's advertised
        // `bodyHash` (PR 4 review N2). The fixture's stored `body_hash` column
        // is left as the daemon-mirror value it really is — a different,
        // non-lowered hash — precisely so that reading it would fail this test.
        let derived = TeamMemoryPullService.teamLocalEngineMemoryID(
            teamID: "team_abcdef0123456789",
            projectID: "proj_fixture",
            engineScope: "project",
            canonicalBodyHash: TeamMemorySyncService.canonicalBodyHash("Retention is ninety days.")
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_team', 'proj_fixture', ?, 'Retention is ninety days.', 'daemon-mirror-hash', ?, ?)
                """,
                arguments: [derived, "2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            // THE ROW ID IS THE NAMESPACED ONE PR 3 ACTUALLY WRITES —
            // `team:<teamId>:<uid>:<cloud doc id>` (PR 3 review MEDIUM-2),
            // because a team document id is shared across members and the inbox
            // `doc_id` is that table's primary key. The lift filters on that
            // prefix and matches on the derivation, never on `doc_id` itself.
            //
            // `TeamMemoryPullService` writes the whole verified payload as
            // `payloadJSON` — the `entryKind` precedent, so no column and no
            // migration — which is the same place `writerDevice` already lives.
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, 'user-1', 'eng_sealed_by_the_author', ?, ?, ?, NULL)
                """,
                arguments: [
                    TeamMemoryPullService.inboxDocID(
                        teamID: "team_abcdef0123456789",
                        localUserID: "user-1",
                        documentID: String(repeating: "b", count: 64)
                    ),
                    // NON-CANONICAL ON PURPOSE, and carrying a `bodyHash` that
                    // is not the key: padded `projectID`, upper-case
                    // `engineScope`, and a `bodyHash` naming a body this device
                    // never stored. The engine strips and lowercases these and
                    // recomputes the hash from the gated body, so a badge that
                    // read them raw would silently not fire here — which is
                    // exactly the redaction case PR 4 review N2 names.
                    #"""
                    {"memoryID":"eng_sealed_by_the_author","teamID":"team_abcdef0123456789",\#
                    "authorUID":"uid-42","projectID":"  proj_fixture ","engineScope":"PROJECT",\#
                    "bodyHash":"the-senders-advice-about-its-own-store"}
                    """#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let record = try await store.memoryTimeline(memoryID: "mem_team", userID: "user-1")
        XCTAssertEqual(record.teamID, "team_abcdef0123456789")
        XCTAssertEqual(record.authorUID, "uid-42")
        // The sealed `engine_memory_id` is NOT what connected them.
        XCTAssertNotEqual(derived, "eng_sealed_by_the_author")

        // A memory that never came from a team names none — which is what the
        // absent badge is built on.
        try await insertAuthorityRow(queue, id: "mem_solo")
        let solo = try await store.memoryTimeline(memoryID: "mem_solo", userID: "user-1")
        XCTAssertNil(solo.teamID)
        XCTAssertNil(solo.authorUID)
    }

    /// The derivation is a CROSS-LANGUAGE contract, so it is pinned as a vector
    /// on both sides.
    ///
    /// `memory_engine/_namespaces.py::_team_local_memory_id` is what actually
    /// lands the row; this Swift copy only has to agree with it, and a silent
    /// disagreement would not fail a build — it would quietly stop badging every
    /// team fact. `test_memory_blind_sync.py` pins the same three vectors.
    func test_the_team_local_id_derivation_matches_the_engine_byte_for_byte() {
        XCTAssertEqual(
            TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: "team_abcdef0123456789",
                projectID: "proj_fixture",
                engineScope: "project",
                canonicalBodyHash: "hash"
            ),
            "mem_67cfa917b1b5e9b3cfde42a2f2967aaf"
        )
        XCTAssertEqual(
            TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: "team_0123456789abcdef",
                projectID: "proj_fixture",
                engineScope: "project",
                canonicalBodyHash: "hash"
            ),
            "mem_89c55a69b98bd82e7a265374b1d649a4"
        )
        // The team id is an input, so two teams sharing one body land apart.
        XCTAssertNotEqual(
            TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: "team_abcdef0123456789",
                projectID: "proj_fixture",
                engineScope: "project",
                canonicalBodyHash: "hash"
            ),
            TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: "team_0123456789abcdef",
                projectID: "proj_fixture",
                engineScope: "project",
                canonicalBodyHash: "hash"
            )
        )
    }

    /// The vector that differs from the pinned one ONLY by canonicalisation
    /// (PR 4 review N2).
    ///
    /// The two literals above pin the hash function; they say nothing about the
    /// input normalisation, which is where the real divergence was.
    /// `_screen_remote_row` derives from `project_id.strip()`,
    /// `engineScope.strip().lower()` and `str(team_id).strip()`, so a payload
    /// that arrives padded or upper-cased lands on the SAME engine row — and a
    /// derivation reading the payload raw would have produced a different id and
    /// silently dropped the badge, which reads identically to "personal".
    func test_the_derivation_canonicalises_its_inputs_the_way_the_engine_does() {
        XCTAssertEqual(
            TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: " team_abcdef0123456789\n",
                projectID: "  proj_fixture ",
                engineScope: "\tPROJECT ",
                canonicalBodyHash: "hash"
            ),
            "mem_67cfa917b1b5e9b3cfde42a2f2967aaf",
            "padding and case must not move a team document to a different local id"
        )
    }

    /// And the body hash the derivation is fed is the ENGINE'S, recomputed.
    ///
    /// `memory_engine/_util.py::canonical_body_hash` is `sha256_hex(body.lower())`.
    /// The daemon-mirror hash the app stores in `agent_memory_bodies.body_hash`
    /// is `sha256_hex(body)` with no lowering — `_util.py:42` says in so many
    /// words that it is a different hash in a different namespace — so the two
    /// part company on any body with one capital letter in it, which is most of
    /// them. Pinned as a literal, and pinned again in Python.
    func test_the_canonical_body_hash_is_the_engines_lowered_one() {
        XCTAssertEqual(
            TeamMemorySyncService.canonicalBodyHash("Body"),
            "230d8358dc8e8890b4c58deeb62912ee2f20357ae92a5cc861b98e68fe31acb5"
        )
        XCTAssertEqual(
            TeamMemorySyncService.canonicalBodyHash("Body"),
            TeamMemorySyncService.canonicalBodyHash("body"),
            "the engine lowercases before hashing, so case cannot split one fact in two"
        )
    }

    /// The walk is BOUNDED, and the bound is real (PR 4 review N4).
    ///
    /// The derivation cannot be indexed or expressed in SQL, so a personal
    /// memory — almost every memory — pays a walk of the member's whole parked
    /// team corpus that can never match. `teamProvenanceScanLimit` caps that
    /// walk. This pins the cap at its edge in BOTH directions, because a cap
    /// that silently swallowed the match would be the worse bug: the match at
    /// position `limit + 1` is not found, the identical match at position
    /// `limit` is.
    func test_the_team_provenance_walk_stops_at_its_scan_bound() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_capped")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_capped",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        let body = "The release train leaves on Thursdays."
        let derived = TeamMemoryPullService.teamLocalEngineMemoryID(
            teamID: "team_abcdef0123456789",
            projectID: "proj_fixture",
            engineScope: "project",
            canonicalBodyHash: TeamMemorySyncService.canonicalBodyHash(body)
        )
        let limit = ControlPlaneStore.teamProvenanceScanLimit
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_capped', 'proj_fixture', ?, ?, 'daemon-mirror-hash', ?, ?)
                """,
                arguments: [derived, body, "2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            // The MATCH is the oldest row, so `ORDER BY remote_updated_at DESC`
            // reaches it last — position `limit + 1`.
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, 'user-1', 'eng_sealed', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', NULL)
                """,
                arguments: [
                    TeamMemoryPullService.inboxDocID(
                        teamID: "team_abcdef0123456789",
                        localUserID: "user-1",
                        documentID: String(repeating: "b", count: 64)
                    ),
                    #"""
                    {"teamID":"team_abcdef0123456789","authorUID":"uid-42",\#
                    "projectID":"proj_fixture","engineScope":"project"}
                    """#
                ]
            )
            // `limit` newer team rows in front of it, each a different team so
            // the per-triple derivation cache cannot collapse the walk.
            for index in 0..<limit {
                let teamID = String(format: "team_%016x", index)
                try db.execute(
                    sql: """
                    INSERT INTO agent_memory_inbox
                        (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                    VALUES (?, 'user-1', 'eng_other', ?, ?, ?, NULL)
                    """,
                    arguments: [
                        TeamMemoryPullService.inboxDocID(
                            teamID: teamID,
                            localUserID: "user-1",
                            documentID: String(format: "%064x", index)
                        ),
                        #"{"teamID":"\#(teamID)","authorUID":"uid-x","projectID":"proj_fixture","engineScope":"project"}"#,
                        // Unique and lexicographically increasing — the column
                        // is TEXT, and every one of these sorts NEWER than the
                        // match's `2026-01-01`.
                        String(format: "2026-09-02T00:00:00.%03dZ", index),
                        "2026-09-09T00:00:00.000Z"
                    ]
                )
            }
        }

        let capped = try await store.memoryTimeline(memoryID: "mem_capped", userID: "user-1")
        XCTAssertNil(capped.teamID, "a match past the scan bound is not reached")

        // Remove ONE row in front of it and the very same match lands.
        try await queue.write { db in
            try db.execute(
                sql: "DELETE FROM agent_memory_inbox WHERE doc_id = ?",
                arguments: [
                    TeamMemoryPullService.inboxDocID(
                        teamID: String(format: "team_%016x", 0),
                        localUserID: "user-1",
                        documentID: String(format: "%064x", 0)
                    )
                ]
            )
        }
        let inBound = try await store.memoryTimeline(memoryID: "mem_capped", userID: "user-1")
        XCTAssertEqual(inBound.teamID, "team_abcdef0123456789")
        XCTAssertEqual(inBound.authorUID, "uid-42")
    }

    // MARK: - Truncation

    /// I2: a capped read used to return the OLDEST page and then call its last
    /// row "last recorded". On a memory with more events than the cap, the header
    /// rendered a stale timestamp as the latest one and nothing said the list was
    /// cut. The cap now takes the tail, and the record says it is a tail.
    func test_a_capped_read_keeps_the_latest_events_and_says_it_was_capped() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_busy")
        for seq in 1 ... 6 {
            try await insertAuditEvent(
                queue,
                seq: seq,
                subjectID: "mem_busy",
                action: "memory.update",
                ts: "2026-09-0\(seq)T00:00:00.000Z"
            )
        }

        let capped = try await store.memoryTimeline(memoryID: "mem_busy", limit: 3)
        XCTAssertEqual(capped.revisions.map(\.seq), [4, 5, 6], "a cap keeps the LATEST events, not the first page")
        XCTAssertEqual(
            capped.lastHelpedAt,
            "2026-09-06T00:00:00.000Z",
            "'last recorded' must be the last event, not the last row of an oldest-first page"
        )
        XCTAssertTrue(capped.truncated, "the member is told older events exist")

        let whole = try await store.memoryTimeline(memoryID: "mem_busy", limit: 50)
        XCTAssertEqual(whole.revisions.map(\.seq), [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(whole.truncated, "a complete history is not a truncated one")

        // Exactly at the cap is still complete.
        let exact = try await store.memoryTimeline(memoryID: "mem_busy", limit: 6)
        XCTAssertEqual(exact.revisions.count, 6)
        XCTAssertFalse(exact.truncated)
    }

    // MARK: - Domain scoping

    /// I5: `memory_audit` is a multi-namespace ledger. The daemon writes
    /// `domain = 'code'` rows into the same table with a completely different
    /// `subject_id` namespace (artifact ids, and filesystem paths for
    /// `code.index`). A memory's history must contain only memory events.
    func test_a_code_domain_event_is_not_rendered_as_memory_history() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_scoped")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_scoped",
            action: "memory.add",
            ts: "2026-09-01T00:00:00.000Z"
        )
        try await insertAuditEvent(
            queue,
            seq: 2,
            subjectID: "mem_scoped",
            action: "code.remember",
            ts: "2026-09-02T00:00:00.000Z",
            domain: "code"
        )

        let record = try await store.memoryTimeline(memoryID: "mem_scoped")

        XCTAssertEqual(record.revisions.map(\.event), ["memory.add"], "a foreign namespace never joins a memory's history")
        XCTAssertEqual(record.revisions.first?.meta["domain"], "memory")
        XCTAssertEqual(record.lastHelpedAt, "2026-09-01T00:00:00.000Z")
    }

    // MARK: - Cross-member scoping

    /// M2: `agent_memory_inbox` is user-scoped and the join was not. On a Mac
    /// where two accounts have signed in, another member's inbox row could name
    /// the device. The read now says whose inbox it is reading, and reads none
    /// when nobody is signed in.
    func test_the_inbound_device_is_read_only_from_the_signed_in_members_inbox() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_shared")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_shared",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_shared', 'proj_fixture', 'eng_shared', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-other', 'user-other', 'eng_shared', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"memoryID":"eng_shared","writerDevice":"someone-elses-mac"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let mine = try await store.memoryTimeline(memoryID: "mem_shared", userID: "user-1")
        XCTAssertNil(mine.writerDevice, "another member's inbox row is not my provenance")
        XCTAssertEqual(mine.status, MemoryTimelineRecord.statusOK)

        let anonymous = try await store.memoryTimeline(memoryID: "mem_shared", userID: nil)
        XCTAssertNil(anonymous.writerDevice, "with nobody signed in there is no inbox to read")

        let theirs = try await store.memoryTimeline(memoryID: "mem_shared", userID: "user-other")
        XCTAssertEqual(theirs.writerDevice, "someone-elses-mac", "their own row is still theirs to see")
    }

    // MARK: - Payload bound

    /// M3: `payload_json` was deserialized whole, unbounded. It is written by
    /// the app's own verified pull lane, so this is a robustness bound rather
    /// than an attack surface — and exceeding it degrades to "no device named",
    /// never to a failed timeline.
    func test_an_oversized_inbox_payload_is_skipped_rather_than_parsed() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_fat")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_fat",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        let padding = String(repeating: "p", count: ControlPlaneStore.memoryTimelinePayloadByteLimit + 1)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_fat', 'proj_fixture', 'eng_fat', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-fat', 'user-1', 'eng_fat', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"writerDevice":"studio-ultra","padding":"\#(padding)"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let record = try await store.memoryTimeline(memoryID: "mem_fat", userID: "user-1")
        XCTAssertEqual(record.status, MemoryTimelineRecord.statusOK, "an oversized payload never fails the timeline")
        XCTAssertEqual(record.revisions.count, 1)
        XCTAssertNil(record.writerDevice, "past the bound the payload is not parsed at all")
    }
}
