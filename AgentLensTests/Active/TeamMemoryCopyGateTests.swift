import XCTest
@testable import OpenBurnBar

/// The team-memory copy is a promise, and these are the four things it has to
/// keep (memory program D16 / P22, design §5 PR 4).
///
/// Two of them are semantics cryptography cannot change — joining reads the
/// whole history, leaving protects only the future — and the shipped alerts must
/// say so in the member's own words, not in a threat model they will never open.
/// The third is that the footnote carries BOTH invariants. The fourth is an
/// in-process mirror of the CI honesty gate, so an over-claim fails in seconds
/// here rather than minutes later in `verify-signal-honesty-copy.sh`.
final class TeamMemoryCopyGateTests: XCTestCase {

    // MARK: Semantic A — joining reads history

    func test_team_join_dialog_displays_semantic_a_historical_access_copy() {
        // VERBATIM, and pinned as a literal rather than a substring: this is the
        // one sentence that stops a member believing a team space starts empty
        // for them. A joiner is issued an envelope for every RETAINED key
        // generation before `promoteTeamMember` will make them active, so
        // "everything sealed before you joined" is what actually happens.
        XCTAssertEqual(
            TeamMemoryCopy.joinSemanticA,
            "Joining a team grants read access to all team memories sealed under the team's active keys, "
                + "including memories contributed by team members before you joined."
        )
        // And it is what the join confirmation shows. The alert renders
        // `joinSemanticA` as its message; the title and the confirm label are
        // pinned so a future edit cannot quietly demote the semantic to a
        // tooltip.
        XCTAssertEqual(TeamMemoryCopy.joinAlertTitle, "Join This Team Space?")
        XCTAssertEqual(TeamMemoryCopy.joinConfirmAction, "Join Team")
        XCTAssertTrue(TeamMemoryCopy.joinSemanticA.contains("before you joined"))
    }

    // MARK: Semantic B — leaving protects the future only

    func test_team_leave_dialog_displays_semantic_b_future_protection_only_copy() {
        XCTAssertEqual(
            TeamMemoryCopy.leaveSemanticB,
            "Leaving or being removed from a team revokes your server access and rotates the team encryption "
                + "key for future memories. However, it cannot erase memories or keys that have already been "
                + "downloaded to your devices."
        )
        XCTAssertEqual(TeamMemoryCopy.leaveAlertTitle, "Leave This Team Space?")
        XCTAssertEqual(TeamMemoryCopy.leaveConfirmAction, "Leave Team")
        // The removal alert an ADMIN sees is the same claim from the other side:
        // removing someone triggers a rotation, and the rotation protects the
        // future only. The destructive label says what the button does.
        XCTAssertEqual(TeamMemoryCopy.alertTitle, "Remove Member from Team?")
        XCTAssertEqual(TeamMemoryCopy.alertDestructiveAction, "Rotate Keys and Remove")
        XCTAssertTrue(TeamMemoryCopy.removeMemberDetail.contains("cannot retract"))
    }

    // MARK: Both invariants in one footnote

    func test_team_settings_footnote_contains_both_invariants() {
        let footnote = TeamMemoryCopy.settingsFootnote
        // Semantic A.
        XCTAssertTrue(
            footnote.contains("existing history"),
            "The footnote must say that joining reaches the team's existing history"
        )
        // Semantic B.
        XCTAssertTrue(
            footnote.contains("future memories only"),
            "The footnote must say that leaving protects future memories only"
        )
        XCTAssertTrue(
            footnote.contains("cannot retract"),
            "The footnote must say rotation retracts nothing already downloaded"
        )
        // The named trust assumption (design §4): a team gate is not a
        // confidentiality boundary BETWEEN members, and the shipped UI says so
        // rather than leaving it in the threat model.
        XCTAssertTrue(
            footnote.contains("every active member holds the team key"),
            "The footnote must name the shared-key trust assumption"
        )
        // "blind", never the over-claim.
        XCTAssertTrue(footnote.contains("blind"), "The footnote must call the lane blind")
    }

    // MARK: The honesty gate, in process

    /// An in-process mirror of the banned list in
    /// `scripts/ci/verify-signal-honesty-copy.sh`.
    ///
    /// KEPT AS A COPY, DELIBERATELY. A test that read the shell script would
    /// pass whenever the script changed, which is the opposite of a gate: two
    /// independent statements of the same rule is what makes a divergence
    /// visible. The CI gate remains the enforcement (it scans this file's text,
    /// so a string this test never sees is still caught); this is the fast local
    /// mirror the design asked for.
    private static let bannedPhrases = [
        "zero-knowledge",
        "zero knowledge",
        "server learns nothing",
        "server searches without reading it",
        "searches without reading",
        "search without reading",
        "signal-quality privacy",
        "semantic memory is private from us",
        "semantic search is private from us",
        "server cannot infer semantic",
        "server cannot infer memory",
        "revocation immediately makes old data safe",
        "no one in the middle",
        "that includes us",
        "couldn't peek",
        "everything between them is end-to-end encrypted",
        "api keys never leave the device",
        "never leave the providers",
        "never appears in a log"
    ]

    func test_no_team_copy_string_contains_a_banned_over_claim() {
        XCTAssertFalse(TeamMemoryCopy.allCopy.isEmpty)
        for copy in TeamMemoryCopy.allCopy {
            let lowered = copy.lowercased()
            for phrase in Self.bannedPhrases {
                XCTAssertFalse(
                    lowered.contains(phrase),
                    "TeamMemoryCopy string contains the banned over-claim \"\(phrase)\": \(copy)"
                )
            }
        }
        // The inventory must actually contain the strings this suite pins, or
        // the loop above would be walking a list that proves nothing.
        for pinned in [
            TeamMemoryCopy.joinSemanticA,
            TeamMemoryCopy.leaveSemanticB,
            TeamMemoryCopy.settingsFootnote,
            TeamMemoryCopy.alertTitle,
            TeamMemoryCopy.alertDestructiveAction,
            TeamMemoryCopy.shareKeysDetail,
            TeamMemoryCopy.teamFactBadgeLabel
        ] {
            XCTAssertTrue(TeamMemoryCopy.allCopy.contains(pinned), "Missing from TeamMemoryCopy.allCopy: \(pinned)")
        }
    }

    // MARK: The admin side of Semantic A

    func test_the_share_team_keys_copy_states_what_promotion_grants() {
        // Semantic A is a promise made to the JOINER, but the irreversible step
        // is taken by an ADMIN — issuing envelopes for every retained key
        // generation and then promoting. The button therefore may not ship
        // without saying, where the admin presses it, that it hands over the
        // team's whole history.
        let detail = TeamMemoryCopy.shareKeysDetail
        XCTAssertTrue(detail.contains("every team key"))
        XCTAssertTrue(detail.contains("before they joined"))
        XCTAssertTrue(detail.contains("every memory this team has sealed"))
        // And the failures say something an admin can act on rather than
        // "something went wrong".
        XCTAssertTrue(TeamMemoryCopy.shareKeysConflictNotice.contains("Nothing was shared"))
        XCTAssertTrue(
            TeamMemoryCopy.shareKeysNoTrustedDevice(member: "uid-42")
                .contains("uid-42 has not published a trusted device")
        )
        XCTAssertTrue(TeamMemoryCopy.shareKeysNoLongerPendingNotice.contains("no longer waiting to join"))
        XCTAssertTrue(TeamMemoryCopy.shareKeysFailedNotice.contains("No member was made active"))
    }

    // MARK: The provenance badge

    func test_the_team_fact_badge_names_the_contributor() {
        XCTAssertEqual(TeamMemoryCopy.teamFactBadgeLabel, "Team Fact")
        XCTAssertEqual(
            TeamMemoryCopy.teamFactAttribution(member: "uid-42"),
            "Team Fact · contributed by uid-42"
        )
    }

    func test_a_team_fact_with_no_author_attributes_the_fact_to_nobody() {
        // PR 4 review L5. The badge used to fall back to the TEAM id, so a fact
        // whose author was dropped read "contributed by team_abcdef0123456789".
        // A team is not a contributor, and this lane's whole thesis is that the
        // copy is the promise.
        XCTAssertEqual(TeamMemoryCopy.teamFactUnknownContributor, "Team Fact · contributor unknown")
        XCTAssertFalse(TeamMemoryCopy.teamFactUnknownContributor.contains("contributed by"))
        XCTAssertTrue(TeamMemoryCopy.teamFactUnknownContributor.hasPrefix(TeamMemoryCopy.teamFactBadgeLabel))
        XCTAssertTrue(TeamMemoryCopy.allCopy.contains(TeamMemoryCopy.teamFactUnknownContributor))
    }

    // MARK: The rotation conflict and its one real remedy

    func test_the_rotation_conflict_copy_never_tells_an_admin_to_retry_the_generation() {
        // PR 4 review §5 hazards 5 and 6. A `rotationConflict` is the one team
        // failure where "try again" is actively wrong: envelope documents are
        // create-only, so the ids that generation needs are occupied forever by
        // wraps of a key this Mac does not hold. The copy has to say what
        // happened, what did NOT happen, and what the real way out is.
        let notice = TeamMemoryCopy.rotationConflictNotice
        XCTAssertTrue(notice.contains("Nothing was written and nothing was shared"), "no partial-write scare")
        XCTAssertTrue(
            notice.contains("wraps a key this Mac does not hold"),
            "the reason this generation cannot be retried, not just that it failed"
        )
        XCTAssertTrue(notice.contains("wait for it to finish"), "the other admin may still be mid-pass")
        XCTAssertFalse(
            notice.lowercased().contains("try again"),
            "retrying this generation is the one thing that cannot work"
        )

        // The recovery names its cost before it is pressed, and names the exact
        // generation it spends.
        let detail = TeamMemoryCopy.abandonGenerationDetail(version: 4)
        XCTAssertTrue(detail.contains("generation 4 as "), "the version is named, never implied")
        XCTAssertTrue(detail.contains("never "), "it says the generation is permanently spent")
        XCTAssertTrue(detail.contains("Pressing this twice is safe"), "the recovery is idempotent and says so")
        XCTAssertFalse(
            detail.lowercased().contains("undo"),
            "burning a generation is a one-way roster write"
        )
        XCTAssertEqual(TeamMemoryCopy.abandonGenerationAction, "Skip That Generation")
        XCTAssertTrue(TeamMemoryCopy.allCopy.contains(TeamMemoryCopy.rotationConflictNotice))
        XCTAssertTrue(TeamMemoryCopy.allCopy.contains(TeamMemoryCopy.abandonGenerationAction))
        XCTAssertTrue(TeamMemoryCopy.allCopy.contains(TeamMemoryCopy.abandonGenerationDetail(version: 4)))
    }

    func test_the_closed_gate_notice_names_every_lever_that_closes_it() {
        // PR 4 review L4. The row is gated on
        // `MemoryDeviceSyncScope.current(...).isOpen` — the personal memory
        // levers AND the account ones — so a notice that named only the two
        // memory switches told a member to turn on things already on.
        let notice = TeamMemoryCopy.personalGateClosedNotice
        XCTAssertTrue(notice.contains("cloud sync for your account"), "the account lever")
        XCTAssertTrue(notice.contains("Back up approved memories"), "the backup opt-in")
        XCTAssertTrue(notice.contains("Sync memories to my other devices"), "the device-sync sub-toggle")
        XCTAssertTrue(notice.contains("any of those"), "any one of them being off is enough to close the lane")
    }

    // MARK: Whether THIS Mac holds the team's keys

    /// The three key-readiness lines, and the two they must not be confused
    /// with.
    ///
    /// Before the founder bootstrap and the joiner pickup had production
    /// callers, EVERY member was permanently in the "no keys" state and the
    /// section said nothing at all — a switch reading available above a lane
    /// that could not seal a single fact. Each line therefore has to name who
    /// acts next, and the two waiting states have to be distinguishable: one is
    /// resolved by an admin's Mac, the other only by this one.
    func test_the_key_readiness_copy_names_who_acts_next() {
        XCTAssertEqual(TeamMemoryCopy.keysReadyNotice, "This Mac holds this team's keys.")

        // Waiting on an ADMIN.
        let awaiting = TeamMemoryCopy.keysAwaitingAdminNotice
        XCTAssertTrue(awaiting.contains("does not hold this team's keys yet"))
        XCTAssertTrue(awaiting.contains("A team admin's Mac"), "it names who acts, not just that nothing works")
        XCTAssertTrue(awaiting.contains("this team syncs nothing"), "and it says what the silence costs")

        // Waiting on THIS Mac.
        let incomplete = TeamMemoryCopy.keysSetupIncompleteNotice
        XCTAssertTrue(incomplete.contains("created on this Mac"))
        XCTAssertTrue(incomplete.contains("did not finish publishing"))
        XCTAssertNotEqual(incomplete, awaiting, "the two waiting states have different remedies")

        // The creation-time report. It must never read as "the team was not
        // created": a founder who believes that creates a second one.
        let created = TeamMemoryCopy.teamCreatedWithoutKeysNotice
        XCTAssertTrue(created.hasPrefix("The team was created"))
        XCTAssertTrue(
            created.contains(TeamMemoryCopy.finishTeamSetupAction),
            "it points at the exact control that resumes the founding"
        )

        for line in [
            TeamMemoryCopy.keysReadyNotice,
            awaiting,
            incomplete,
            created,
            TeamMemoryCopy.finishTeamSetupAction,
            TeamMemoryCopy.finishTeamSetupDetail,
            TeamMemoryCopy.finishTeamSetupFailedNotice,
            TeamMemoryCopy.keysFoundedOnAnotherDeviceNotice
        ] {
            XCTAssertTrue(TeamMemoryCopy.allCopy.contains(line), "Missing from TeamMemoryCopy.allCopy: \(line)")
        }
    }

    /// The founding action says what it costs and what it will not do, and the
    /// second-Mac refusal never tells a member to retry something that refuses
    /// for ever.
    func test_the_founding_action_copy_is_honest_about_idempotence_and_refusal() {
        XCTAssertEqual(TeamMemoryCopy.finishTeamSetupAction, "Finish Setting Up Keys")

        let detail = TeamMemoryCopy.finishTeamSetupDetail
        XCTAssertTrue(detail.contains("Pressing it more than once is safe"))
        XCTAssertTrue(
            detail.contains("reuses the keys this Mac already made"),
            "the pending-slot guarantee, in the member's words"
        )
        XCTAssertTrue(
            detail.contains("stops without changing anything"),
            "the second-Mac refusal is disclosed before the press, not only after it"
        )

        // The ordinary failure is a retry, and says so.
        XCTAssertTrue(TeamMemoryCopy.finishTeamSetupFailedNotice.contains("No key was published"))
        XCTAssertTrue(TeamMemoryCopy.finishTeamSetupFailedNotice.contains("try again"))

        // The fork refusal is NOT a retry, and must not be worded as one.
        let refusal = TeamMemoryCopy.keysFoundedOnAnotherDeviceNotice
        XCTAssertTrue(refusal.contains("created on another of your Macs"))
        XCTAssertTrue(refusal.contains("Finish setting the team up there"), "it names the machine that can finish")
        XCTAssertFalse(
            refusal.lowercased().contains("try again"),
            "pressing this Mac's button again refuses for ever, by design"
        )
    }
}
