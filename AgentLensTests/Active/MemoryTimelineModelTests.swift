import XCTest
@testable import OpenBurnBar

/// B8: the timeline model is the view half of a memory's history. Its loader
/// closure stands in for whichever history is being read — today the app's own
/// `memory_audit` ledger via `ControlPlaneStore.memoryTimeline`, tomorrow a
/// daemon-forwarded engine read — which is why every result carries `source`.
/// The contract it must satisfy is documented on `MemoryTimelineModel`.
@MainActor
final class MemoryTimelineModelTests: XCTestCase {

    private func revision(
        seq: Int,
        event: String,
        writerDevice: String? = nil,
        after: String? = nil,
        before: String? = nil,
        meta: [String: String] = [:]
    ) -> MemoryTimelineModel.RevisionItem {
        MemoryTimelineModel.RevisionItem(
            seq: seq,
            event: event,
            actor: "user",
            ts: "2026-09-05T10:0\(seq):00Z",
            before: before,
            after: after,
            writerDevice: writerDevice,
            meta: meta
        )
    }

    /// Revisions render in `seq` order whatever order the read returned them in —
    /// the timeline is a history, so out-of-order rows would read as a lie.
    func test_timeline_returns_revisions_in_order() async {
        let created = revision(seq: 1, event: "memory.add", writerDevice: "macbook-air")
        let updated = revision(seq: 2, event: "memory.update", writerDevice: "macbook-pro")
        let retired = revision(seq: 3, event: "memory.delete", writerDevice: "macbook-pro")

        let model = MemoryTimelineModel(memoryID: "mem_123") { memoryID, projectPath in
            XCTAssertEqual(memoryID, "mem_123")
            XCTAssertNil(projectPath)
            return MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [updated, retired, created]
            )
        }

        await model.load()

        XCTAssertFalse(model.isRefused)
        XCTAssertFalse(model.isNotFound)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.revisions.map(\.seq), [1, 2, 3])
        XCTAssertEqual(model.revisions.map(\.displayEvent), ["Created", "Updated", "Retired"])
        XCTAssertEqual(model.source, MemoryTimelineSource.appAudit)
    }

    // MARK: - Team provenance (memory program D16 / P22, PR 4)

    func test_a_team_fact_is_badged_with_its_team_and_contributor() async {
        // The badge reads the SAME two fields PR 3 lands and invents none:
        // `TeamMemoryPullService` writes `teamID` and `authorUID` inside the
        // parked `payloadJSON`, which is exactly where `writerDevice` already
        // comes from, and `ControlPlaneStore.memoryTimeline` lifts all three
        // through one parser.
        let model = MemoryTimelineModel(
            memoryID: "mem_team",
            loadTimeline: { memoryID, _ in
                MemoryTimelineModel.TimelineResult(
                    memoryID: memoryID,
                    revisions: [self.revision(seq: 1, event: "memory.add")],
                    writerDevice: "macbook-pro",
                    teamID: "team_abcdef0123456789",
                    authorUID: "uid-42"
                )
            },
            listedTeamIDs: { ["team_abcdef0123456789"] }
        )
        await model.load()
        XCTAssertEqual(model.teamFactBadge, "Team Fact · contributed by uid-42")
    }

    func test_a_personal_memory_carries_no_team_badge() async {
        // Absence is the honest signal. An "unknown team" label on every
        // personal row would be noise that says nothing, and almost every row
        // is personal.
        let model = MemoryTimelineModel(memoryID: "mem_personal") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "memory.add")],
                writerDevice: "macbook-pro"
            )
        }
        await model.load()
        XCTAssertNil(model.teamFactBadge)
    }

    func test_a_team_fact_whose_author_was_dropped_says_so_rather_than_naming_the_team() async {
        // `authorUID` is dropped-but-landed on the engine side, so a payload can
        // reach here with a team and no author. Falling back to "personal" would
        // be one wrong answer — the row DID come from a team space — and
        // attributing it to the TEAM id is the other (PR 4 review L5): a team
        // does not contribute facts, its members do.
        let model = MemoryTimelineModel(
            memoryID: "mem_team",
            loadTimeline: { memoryID, _ in
                MemoryTimelineModel.TimelineResult(
                    memoryID: memoryID,
                    revisions: [self.revision(seq: 1, event: "memory.add")],
                    teamID: "team_abcdef0123456789",
                    authorUID: ""
                )
            },
            listedTeamIDs: { ["team_abcdef0123456789"] }
        )
        await model.load()
        XCTAssertEqual(model.teamFactBadge, "Team Fact · contributor unknown")
        XCTAssertEqual(model.teamFactBadge, TeamMemoryCopy.teamFactUnknownContributor)
        // The badge still fires, and it still says "Team Fact".
        XCTAssertEqual(model.teamFactBadge?.hasPrefix(TeamMemoryCopy.teamFactBadgeLabel), true)
        // No identifier of any kind is invented in its place.
        XCTAssertEqual(model.teamFactBadge?.contains("team_abcdef0123456789"), false)
    }

    func test_a_fact_from_a_team_this_mac_no_longer_lists_drops_the_contributor() async {
        // PR 4 review N5. The store's lift is scoped to the member and the
        // `team:` doc-id prefix and NEVER to the roster, so a fact parked from a
        // team the member has since left still badges — correctly, because the
        // fact did come from there. What was wrong was rendering it identically
        // to a live team's fact: `contributed by <uid>` reads as a current
        // membership, and the uid is only interpretable against a roster this
        // member can no longer read.
        let model = MemoryTimelineModel(
            memoryID: "mem_team",
            loadTimeline: { memoryID, _ in
                MemoryTimelineModel.TimelineResult(
                    memoryID: memoryID,
                    revisions: [self.revision(seq: 1, event: "memory.add")],
                    teamID: "team_abcdef0123456789",
                    authorUID: "uid-42"
                )
            },
            // `leaveTeam` calls `directory.forget(teamID:)`, so this is exactly
            // what this Mac's list looks like after a leave.
            listedTeamIDs: { ["team_0123456789abcdef"] }
        )
        await model.load()
        XCTAssertEqual(model.teamFactBadge, TeamMemoryCopy.teamFactFormerTeam)
        // It is still a Team Fact — reading as personal would be the worse error.
        XCTAssertEqual(model.teamFactBadge?.hasPrefix(TeamMemoryCopy.teamFactBadgeLabel), true)
        // And it names neither the contributor nor the team: the local cache
        // holds team IDS and no names, so there is nothing honest to render.
        XCTAssertEqual(model.teamFactBadge?.contains("uid-42"), false)
        XCTAssertEqual(model.teamFactBadge?.contains("team_abcdef0123456789"), false)
    }

    /// The writing device is the point of the packet: a member with two machines
    /// has to be able to see which one wrote a revision — when the history being
    /// read records one at all.
    func test_timeline_reports_the_writing_device_per_revision() async {
        let model = MemoryTimelineModel(memoryID: "mem_456") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [
                    self.revision(seq: 1, event: "created", writerDevice: "studio-ultra"),
                    self.revision(seq: 2, event: "synced", writerDevice: nil)
                ],
                writerDevice: "studio-ultra"
            )
        }

        await model.load()

        XCTAssertEqual(model.revisions.map(\.writerDevice), ["studio-ultra", nil])
        XCTAssertEqual(model.revisions[1].displayEvent, "Synced")
        XCTAssertEqual(model.writerDevice, "studio-ultra")
    }

    /// A foreign memory id is refused, and the refusal renders NOTHING — no
    /// revisions, no lineage, no last-helped. Even a server that refused and
    /// answered anyway cannot leak through this model.
    func test_a_refused_foreign_memory_shows_no_content() async {
        let model = MemoryTimelineModel(
            memoryID: "mem_foreign",
            projectPath: "/tmp/project-a"
        ) { memoryID, projectPath in
            XCTAssertEqual(projectPath, "/tmp/project-a")
            return MemoryTimelineModel.TimelineResult(
                status: MemoryTimelineRecord.statusRefused,
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "created", after: "leaked body")],
                lastHelpedAt: "2026-09-05T10:30:00Z",
                lastHelpedSource: "recall_serve",
                code: "FOREIGN_PROJECT",
                validFrom: "2026-01-01T00:00:00Z",
                supersededBy: "mem_leak",
                writerDevice: "leaked-device"
            )
        }

        await model.load()

        XCTAssertTrue(model.isRefused)
        XCTAssertEqual(model.code, "FOREIGN_PROJECT")
        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertNil(model.lastHelpedAt)
        XCTAssertNil(model.lastHelpedSource)
        XCTAssertNil(model.validFrom)
        XCTAssertNil(model.supersededBy)
        XCTAssertNil(model.writerDevice)
    }

    /// "Last helped" carries its source, because a recall-serve event and a
    /// history event mean different things to a member deciding whether to keep
    /// a memory. The app's own ledger can only justify `history`.
    func test_last_helped_carries_its_source() async {
        for source in ["recall_serve", MemoryTimelineRecord.lastHelpedSourceHistory] {
            let model = MemoryTimelineModel(memoryID: "mem_helped") { memoryID, _ in
                MemoryTimelineModel.TimelineResult(
                    memoryID: memoryID,
                    lastHelpedAt: "2026-09-05T10:30:00Z",
                    lastHelpedSource: source
                )
            }

            await model.load()

            XCTAssertEqual(model.lastHelpedAt, "2026-09-05T10:30:00Z")
            XCTAssertEqual(model.lastHelpedSource, source)
        }
    }

    /// An id the history does not know is `not_found` — a distinct state from a
    /// successful read with no events, which the view must not render as
    /// "this memory has never been touched".
    func test_an_unknown_memory_is_not_found_rather_than_an_empty_success() async {
        let notFound = MemoryTimelineModel(memoryID: "mem_gone") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                status: MemoryTimelineRecord.statusNotFound,
                memoryID: memoryID
            )
        }
        await notFound.load()
        XCTAssertTrue(notFound.isNotFound)
        XCTAssertFalse(notFound.isRefused)
        XCTAssertTrue(notFound.revisions.isEmpty)
        XCTAssertNil(notFound.errorMessage)

        let emptyOK = MemoryTimelineModel(memoryID: "mem_quiet") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(memoryID: memoryID)
        }
        await emptyOK.load()
        XCTAssertFalse(emptyOK.isNotFound)
        XCTAssertTrue(emptyOK.revisions.isEmpty)
    }

    /// The app's ledger keeps no revision contents, and the result says so, so
    /// the view can tell the member "not retained" instead of leaving nil
    /// `before`/`after` to read as "unchanged".
    func test_a_result_that_retains_no_revision_bodies_says_so() async {
        let model = MemoryTimelineModel(memoryID: "mem_bodies") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "memory.add")]
            )
        }

        await model.load()

        XCTAssertFalse(model.revisionBodiesRetained)
        XCTAssertTrue(model.revisions.allSatisfy { $0.before == nil && $0.after == nil })
    }

    /// A read that never came back leaves the model empty and says why, rather
    /// than presenting an empty history as a fact about the memory.
    func test_a_failed_read_surfaces_an_error_and_no_revisions() async {
        let model = MemoryTimelineModel(memoryID: "mem_err") { _, _ in
            throw MemoryTimelineError.historyUnavailable("no such table: memory_audit")
        }

        await model.load()

        XCTAssertEqual(model.errorMessage, "History unavailable — no such table: memory_audit")
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefused)
        XCTAssertFalse(model.isNotFound)
        XCTAssertTrue(model.revisions.isEmpty)
    }

    // MARK: - Model lifetime

    /// Records how many times the loader ran, across an `@escaping` closure.
    @MainActor
    private final class LoadRecorder {
        var memoryIDs: [String] = []
    }

    /// I1: `MemoryTimelineModel` loads once, from `.task`, which fires on appear
    /// and never again. Building it inside a `@ViewBuilder` therefore discards a
    /// loaded history every time the parent re-renders — and the inbox is
    /// `@Observable`, so approving ANY row re-renders every row. The freshly
    /// built model would then render "Nothing has happened to this memory yet."
    /// about a memory that demonstrably has history. The box is what the row
    /// holds in `@State` so that cannot happen.
    func test_the_history_box_keeps_one_loaded_model_per_memory_across_re_renders() async {
        let recorder = LoadRecorder()
        let loader: MemoryTimelineModel.LoadTimeline = { memoryID, _ in
            recorder.memoryIDs.append(memoryID)
            return MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [
                    MemoryTimelineModel.RevisionItem(
                        seq: 1,
                        event: "memory.add",
                        actor: "app",
                        ts: "2026-09-05T10:01:00Z"
                    )
                ]
            )
        }

        let box = MemoryTimelineModelBox()
        let first = box.model(for: "mem_a", loadTimeline: loader)
        await first.load()
        XCTAssertEqual(first.revisions.map(\.seq), [1])

        // The sibling re-render.
        let again = box.model(for: "mem_a", loadTimeline: loader)
        XCTAssertIdentical(again, first, "the same memory keeps the same model")
        XCTAssertEqual(again.revisions.map(\.seq), [1], "the loaded history survives a re-render")
        XCTAssertEqual(recorder.memoryIDs, ["mem_a"], "a re-render must not re-load, nor blank the history")

        // A different memory is a different subject and gets its own model.
        let other = box.model(for: "mem_b", loadTimeline: loader)
        XCTAssertNotIdentical(other, first)
        XCTAssertEqual(other.memoryID, "mem_b")
        XCTAssertTrue(other.revisions.isEmpty)
    }

    // MARK: - Provenance in every rendered state

    /// M4: the "this is an audit ledger, not the engine's revision bodies" line
    /// was rendered only alongside revisions, so the two states most likely to be
    /// misread — an empty history and an unknown id — carried no provenance at
    /// all. Every state that got an answer states where the answer came from.
    func test_every_answered_state_states_its_provenance() async {
        let empty = MemoryTimelineModel(memoryID: "mem_empty") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(memoryID: memoryID)
        }
        await empty.load()
        let emptyNote = empty.provenanceNote
        XCTAssertNotNil(emptyNote, "an empty history still has a source")
        XCTAssertEqual(emptyNote?.contains("not retained"), true)

        let missing = MemoryTimelineModel(memoryID: "mem_missing") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                status: MemoryTimelineRecord.statusNotFound,
                memoryID: memoryID
            )
        }
        await missing.load()
        XCTAssertNotNil(missing.provenanceNote)

        // A read that never came back has no source to name.
        let failed = MemoryTimelineModel(memoryID: "mem_failed") { _, _ in
            throw MemoryTimelineError.historyUnavailable("no such table: memory_audit")
        }
        await failed.load()
        XCTAssertNil(failed.provenanceNote, "a failed read must not claim a ledger it never reached")
    }

    // MARK: - Truncation

    /// I2: a capped read must say it was capped. Without it the view renders the
    /// oldest page of a busy memory as the whole history.
    func test_a_truncated_result_says_so() async {
        let model = MemoryTimelineModel(memoryID: "mem_busy") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [
                    MemoryTimelineModel.RevisionItem(seq: 9, event: "memory.update", actor: "app", ts: "t9")
                ],
                truncated: true
            )
        }
        await model.load()

        XCTAssertTrue(model.truncated)
        let note = try? XCTUnwrap(model.truncationNote)
        XCTAssertEqual(note?.contains("older"), true, "the member is told there are older events, got \(note ?? "nil")")
    }
}
