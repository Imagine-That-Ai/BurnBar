import FirebaseFunctions
import XCTest
@testable import OpenBurnBar

/// The Settings surface for team memory (memory program D16 / P22, PR 4).
///
/// What these prove, in one sentence each: the switch never reads "on" while a
/// lever above it is shut and always says which one; consent is per team and
/// nothing else; leaving takes the consent with it; the member list is a read;
/// and the rotation row tells "the roster rotated" apart from "the corpus is
/// actually re-keyed", including when a pass skipped documents.
@MainActor
final class TeamMemorySectionModelTests: XCTestCase {

    // MARK: Fakes

    private struct FakeDirectory: TeamMembershipDirectory {
        final class Box: @unchecked Sendable {
            var ids: [String] = []
        }
        let box = Box()
        func knownTeamIDs() -> [String] { box.ids.sorted() }
        func remember(teamID: String) { if !box.ids.contains(teamID) { box.ids.append(teamID) } }
        func forget(teamID: String) { box.ids.removeAll { $0 == teamID } }
    }

    private final class FakeRoster: TeamRosterDirectoryReading, @unchecked Sendable {
        var details: [String: TeamRosterDetail]
        private let lock = NSLock()
        private var readCount = 0
        var reads: Int { lock.withLock { readCount } }

        init(details: [String: TeamRosterDetail]) { self.details = details }

        func rosterDetail(teamID: String, uid: String) async throws -> TeamRosterDetail? {
            lock.withLock { readCount += 1 }
            return details[teamID]
        }
    }

    /// Records the join sequence instead of running it, so a test can assert
    /// WHICH uid was promoted and against WHICH retained generations — and can
    /// observe the model mid-flight through `probe`.
    private final class FakeJoinerKeys: TeamJoinerKeyIssuing, @unchecked Sendable {
        struct Issue: Equatable {
            let teamID: String
            let joinerUid: String
            let retainedKeyVersions: [Int]
        }

        private let lock = NSLock()
        private var recorded: [Issue] = []
        var issues: [Issue] { lock.withLock { recorded } }
        var error: Error?
        var probe: (@Sendable @MainActor () -> Void)?

        func issueKeys(teamID: String, joinerUid: String, retainedKeyVersions: [Int]) async throws {
            lock.withLock {
                recorded.append(
                    Issue(teamID: teamID, joinerUid: joinerUid, retainedKeyVersions: retainedKeyVersions)
                )
            }
            if let probe { await probe() }
            if let error { throw error }
        }
    }

    /// Returns a fixed pass result and records which team it was asked to
    /// rotate, so a test can prove the counters land under that team and no
    /// other.
    private final class FakeRotator: TeamKeyRotating, @unchecked Sendable {
        struct Abandonment: Equatable {
            let teamID: String
            let conflictingVersion: Int
            let activeKeyVersion: Int
            let burnedKeyVersions: [Int]
            let activeMemberUids: [String]
        }

        let progress: TeamCloudVaultRewrapProgress
        private let lock = NSLock()
        private var teams: [String] = []
        private var burned: [[Int]] = []
        private var abandonments: [Abandonment] = []
        private var queuedRotationErrors: [Error] = []
        var rotated: [String] { lock.withLock { teams } }
        /// The burned list each `rotate` was handed, so a test can prove the
        /// roster's list reached the client that picks the next version.
        var rotatedWithBurned: [[Int]] { lock.withLock { burned } }
        var abandoned: [Abandonment] { lock.withLock { abandonments } }

        init(progress: TeamCloudVaultRewrapProgress) { self.progress = progress }

        /// Make the next `rotate` record its attempt and then throw. Queued, so
        /// one test can model "refused, then recovered".
        func failNextRotation(with error: Error) {
            lock.withLock { queuedRotationErrors.append(error) }
        }

        func rotate(
            teamID: String,
            activeKeyVersion: Int,
            burnedKeyVersions: [Int],
            activeMemberUids: [String]
        ) async throws -> TeamCloudVaultRewrapProgress {
            let failure: Error? = lock.withLock {
                teams.append(teamID)
                burned.append(burnedKeyVersions)
                return queuedRotationErrors.isEmpty ? nil : queuedRotationErrors.removeFirst()
            }
            if let failure { throw failure }
            return progress
        }

        func abandonConflictingGenerationAndRotate(
            teamID: String,
            conflictingVersion: Int,
            activeKeyVersion: Int,
            burnedKeyVersions: [Int],
            activeMemberUids: [String]
        ) async throws -> TeamCloudVaultRewrapProgress {
            lock.withLock {
                abandonments.append(
                    Abandonment(
                        teamID: teamID,
                        conflictingVersion: conflictingVersion,
                        activeKeyVersion: activeKeyVersion,
                        burnedKeyVersions: burnedKeyVersions,
                        activeMemberUids: activeMemberUids
                    )
                )
            }
            return progress
        }
    }

    /// Records the founding bootstrap instead of running it, and can refuse the
    /// way the production seam refuses.
    private final class FakeFounderKeys: TeamFounderKeyBootstrapping, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var teamIDs: [String] { lock.withLock { recorded } }
        var error: Error?
        /// Founding slots whose local mint the bootstrap threw away because the
        /// team's real key had already arrived. A SUCCESS that still owes the
        /// member a sentence — see `report(discard:)`.
        var discardedLocalMintSlots: [TeamKeySlot] = []

        func bootstrapKeys(teamID: String) async throws -> TeamKeyBootstrap {
            lock.withLock { recorded.append(teamID) }
            if let error { throw error }
            return TeamKeyBootstrap(
                teamKeyVersion: 1,
                slugKeyId: "slug-key-id",
                envelopeIds: ["e1", "e2"],
                discardedLocalMintSlots: discardedLocalMintSlots
            )
        }
    }

    private static func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A callable error shaped the way the Apple Functions SDK builds one: the
    /// status code, the human message, and the server's `details` payload under
    /// `FunctionsErrorDetailsKey`. `functions/src/teamRosterReasons.ts` puts the
    /// reason there and `functions/src/__tests__/teamRosterReasonCodes.test.ts`
    /// asserts the wire body carries it, so this is the same shape from the other
    /// end of the wire.
    private static func functionsError(
        _ code: FunctionsErrorCode,
        _ message: String,
        reason: String
    ) -> NSError {
        NSError(
            domain: FunctionsErrorDomain,
            code: code.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                FunctionsErrorDetailsKey: ["reason": reason] as NSDictionary
            ]
        )
    }

    private final class FakeAdmin: TeamMemoryAdministering, @unchecked Sendable {
        var created: [String] = []
        var accepted: [(String, String)] = []
        var invited: [(String, String, String)] = []
        var removed: [(String, String)] = []
        var newTeamID = "team_aaaaaaaaaaaaaaaa"
        /// Set to make `removeMember` refuse, the way a roster that still lists
        /// the member does.
        var removeError: Error?

        func createTeam(name: String) async throws -> String {
            created.append(name)
            return newTeamID
        }

        func acceptInvite(teamID: String, inviteToken: String) async throws {
            accepted.append((teamID, inviteToken))
        }

        func inviteMember(teamID: String, email: String, role: String) async throws -> String {
            invited.append((teamID, email, role))
            return "inv_\(String(repeating: "a", count: 40))"
        }

        func removeMember(teamID: String, targetUid: String) async throws {
            if let removeError { throw removeError }
            removed.append((teamID, targetUid))
        }
    }

    private enum TeamMemorySectionModelTestError: Error {
        case refused
    }

    private static func detail(
        teamID: String = "team_aaaaaaaaaaaaaaaa",
        activeKeyVersion: Int = 2,
        burnedKeyVersions: [Int] = [],
        slugKeyRecorded: Bool = true,
        keyRotationRequired: Bool = false,
        rewrapCompletedKeyVersion: Int? = nil,
        myRole: String? = "admin",
        myStatus: String? = "active",
        members: [TeamRosterDetail.Member] = [
            TeamRosterDetail.Member(uid: "me", role: "admin", status: "active"),
            TeamRosterDetail.Member(uid: "them", role: "member", status: "active")
        ]
    ) -> TeamRosterDetail {
        TeamRosterDetail(
            teamID: teamID,
            name: "Platform",
            activeKeyVersion: activeKeyVersion,
            retainedKeyVersions: Array(1...max(1, activeKeyVersion)),
            burnedKeyVersions: burnedKeyVersions,
            slugKeyRecorded: slugKeyRecorded,
            keyRotationRequired: keyRotationRequired,
            rewrapCompletedKeyVersion: rewrapCompletedKeyVersion,
            rewrapJobId: rewrapCompletedKeyVersion == nil ? nil : "job-1",
            myRole: myRole,
            myStatus: myStatus,
            members: members
        )
    }

    private func makeModel(
        detail: TeamRosterDetail,
        personalGateOpen: Bool = true,
        remoteConfigAllowed: Bool = true,
        remoteConfigResolved: Bool = true,
        optedIn: Set<String> = [],
        admin: FakeAdmin = FakeAdmin(),
        directory: FakeDirectory = FakeDirectory(),
        joinerKeys: FakeJoinerKeys? = nil,
        founderKeys: FakeFounderKeys? = nil,
        keyReadiness: TeamKeyReadiness = .unknown,
        roster: FakeRoster? = nil,
        invalidations: InvalidationRecorder? = nil
    ) -> (TeamMemorySectionModel, FakeAdmin, FakeDirectory, () -> Set<String>) {
        directory.remember(teamID: detail.teamID)
        final class OptInBox: @unchecked Sendable { var value: Set<String> = [] }
        let box = OptInBox()
        box.value = optedIn
        let model = TeamMemorySectionModel(
            directory: directory,
            roster: roster ?? FakeRoster(details: [detail.teamID: detail]),
            admin: admin,
            joinerKeys: joinerKeys,
            founderKeys: founderKeys,
            uidProvider: { "me" },
            personalGateProvider: { personalGateOpen },
            remoteConfigProvider: { (remoteConfigAllowed, remoteConfigResolved) },
            optInProvider: { box.value },
            optInWriter: { box.value = $0 },
            keyReadinessProvider: { _ in keyReadiness },
            invalidateTeamSync: { teamID in invalidations?.record(teamID) }
        )
        return (model, admin, directory, { box.value })
    }

    /// Records which teams had their local sync records retired, in order.
    private final class InvalidationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var teamIDs: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func record(_ teamID: String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(teamID)
        }
    }

    // MARK: The gate

    func test_the_toggle_is_disabled_and_explained_when_the_personal_gate_is_closed() async {
        let (model, _, _, _) = makeModel(detail: Self.detail(), personalGateOpen: false)
        await model.refresh()
        let row = try? XCTUnwrap(model.rows.first)
        XCTAssertEqual(row?.availability, .personalGateClosed)
        XCTAssertEqual(row?.availability.isAvailable, false)
        // A greyed switch with no reason is how a member concludes the app is
        // broken. The reason has to be the one they can act on.
        XCTAssertEqual(row?.availability.explanation, TeamMemoryCopy.personalGateClosedNotice)
    }

    func test_the_fleet_ceiling_holds_the_toggle_closed_until_it_resolves() async {
        // CLOSED UNTIL RESOLVED (KD12). The RC field defaults to the optimistic
        // `true`, so "allowed but not yet asked" must not open the lane.
        let (model, _, _, _) = makeModel(
            detail: Self.detail(),
            remoteConfigAllowed: true,
            remoteConfigResolved: false
        )
        await model.refresh()
        XCTAssertEqual(model.rows.first?.availability, .fleetCeilingClosed)
        XCTAssertEqual(model.rows.first?.availability.explanation, TeamMemoryCopy.remoteConfigClosedNotice)
    }

    func test_a_pending_join_shows_the_waiting_for_keys_state() async {
        let (model, _, _, _) = makeModel(
            detail: Self.detail(myRole: "member", myStatus: "pending")
        )
        await model.refresh()
        XCTAssertEqual(model.rows.first?.availability, .pendingJoin)
        XCTAssertEqual(model.rows.first?.availability.explanation, TeamMemoryCopy.pendingJoinNotice)
        XCTAssertTrue(TeamMemoryCopy.pendingJoinNotice.contains("team admin to share the team keys"))
        XCTAssertEqual(model.rows.first?.detail.isMemberPending, true)
        XCTAssertEqual(model.rows.first?.detail.isAdmin, false)
    }

    func test_a_removed_member_is_not_offered_the_toggle() async {
        let (model, _, _, _) = makeModel(detail: Self.detail(myRole: "member", myStatus: "removed"))
        await model.refresh()
        XCTAssertEqual(model.rows.first?.availability, .notAMember)
    }

    // MARK: Consent

    func test_opting_a_team_in_writes_only_that_team() async {
        let (model, _, _, optedIn) = makeModel(detail: Self.detail(), optedIn: ["team_bbbbbbbbbbbbbbbb"])
        await model.refresh()
        model.setOptIn(true, teamID: "team_aaaaaaaaaaaaaaaa")
        // Consent to share with one team is not consent to share with another,
        // so the OTHER team's opt-in must survive untouched.
        XCTAssertEqual(optedIn(), ["team_aaaaaaaaaaaaaaaa", "team_bbbbbbbbbbbbbbbb"])
        XCTAssertEqual(model.rows.first?.optedIn, true)

        model.setOptIn(false, teamID: "team_aaaaaaaaaaaaaaaa")
        XCTAssertEqual(optedIn(), ["team_bbbbbbbbbbbbbbbb"])
        XCTAssertEqual(model.rows.first?.optedIn, false)
    }

    func test_leaving_a_team_clears_its_consent_and_forgets_it_locally() async {
        let detail = Self.detail()
        let (model, admin, directory, optedIn) = makeModel(detail: detail, optedIn: [detail.teamID])
        await model.refresh()
        await model.leaveTeam(teamID: detail.teamID)

        // Self-leave goes through the same callable an admin removal does.
        XCTAssertEqual(admin.removed.count, 1)
        XCTAssertEqual(admin.removed.first?.0, detail.teamID)
        XCTAssertEqual(admin.removed.first?.1, "me")
        // Leaving a consent record behind would mean re-joining silently
        // resumed contribution.
        XCTAssertTrue(optedIn().isEmpty)
        XCTAssertTrue(directory.knownTeamIDs().isEmpty)
    }

    /// Leaving retires this team's local sync records NOW (PR 4 review §3).
    ///
    /// `TeamMemorySyncDomain.runCycle` already drops the pull cursor, push
    /// watermark and project-link record of every team outside the opted-in set,
    /// so correctness never depended on this — LATENCY did. The cycle runs on
    /// `BehaviorSettings.refreshInterval` (600 s by default, up to 15 minutes,
    /// stretched 5x while the app is inactive, which a menu-bar app normally
    /// is), so a leave and a re-join inside that window means no cycle ever
    /// observed the set without this team in it, and the stale pull cursor
    /// resumes past every fact written during the gap.
    func test_leaving_a_team_retires_its_local_sync_records_immediately() async {
        let detail = Self.detail()
        let invalidations = InvalidationRecorder()
        let (model, _, _, _) = makeModel(
            detail: detail,
            optedIn: [detail.teamID],
            invalidations: invalidations
        )
        await model.refresh()
        await model.leaveTeam(teamID: detail.teamID)
        XCTAssertEqual(invalidations.teamIDs, [detail.teamID])
    }

    /// ...and only when the leave actually happened.
    ///
    /// The invalidation sits inside the same `do` block as the callable, so a
    /// refused removal — the member is still on the roster — leaves the local
    /// records exactly where a member who is still in the team needs them.
    func test_a_failed_leave_retires_nothing_locally() async {
        let detail = Self.detail()
        let invalidations = InvalidationRecorder()
        let admin = FakeAdmin()
        admin.removeError = TeamMemorySectionModelTestError.refused
        let (model, _, directory, optedIn) = makeModel(
            detail: detail,
            optedIn: [detail.teamID],
            admin: admin,
            invalidations: invalidations
        )
        await model.refresh()
        await model.leaveTeam(teamID: detail.teamID)
        XCTAssertTrue(invalidations.teamIDs.isEmpty)
        // And nothing else local moved either: the member is still in the team.
        XCTAssertEqual(optedIn(), [detail.teamID])
        XCTAssertEqual(directory.knownTeamIDs(), [detail.teamID])
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: The roster is server-owned

    func test_the_member_list_is_read_from_the_roster_and_never_written() async {
        let (model, admin, _, _) = makeModel(detail: Self.detail())
        await model.refresh()
        XCTAssertEqual(model.rows.first?.detail.members.map(\.uid), ["me", "them"])
        // Nothing about rendering the roster writes to it: `firestore.rules`
        // says `allow write: if false` on every roster path, so an optimistic
        // local edit could only be a lie the next refresh erases.
        XCTAssertTrue(admin.removed.isEmpty)
        XCTAssertTrue(admin.created.isEmpty)
        XCTAssertTrue(TeamMemoryCopy.memberListCaption.contains("read-only"))
    }

    func test_an_admin_removal_is_the_rotation_flow_not_a_roster_edit() async {
        let (model, admin, _, _) = makeModel(detail: Self.detail())
        await model.refresh()
        await model.removeMember(teamID: "team_aaaaaaaaaaaaaaaa", targetUid: "them")
        XCTAssertEqual(admin.removed.first?.1, "them")
        // The button that fires this says what it does: `removeTeamMember` sets
        // `keyRotationRequired`, so the destructive label promises a rotation.
        XCTAssertEqual(TeamMemoryCopy.alertDestructiveAction, "Rotate Keys and Remove")
    }

    // MARK: Sharing a joiner's keys (design §3(b)2)

    private static func pendingJoinerDetail(activeKeyVersion: Int = 3) -> TeamRosterDetail {
        detail(
            activeKeyVersion: activeKeyVersion,
            myRole: "admin",
            myStatus: "active",
            members: [
                TeamRosterDetail.Member(uid: "me", role: "admin", status: "active"),
                TeamRosterDetail.Member(uid: "joiner", role: "member", status: "pending")
            ]
        )
    }

    func test_an_admin_can_share_team_keys_with_a_pending_member() async {
        // The whole point of PR 4's largest gap: without this the joiner sits at
        // "waiting for a team admin to share the team keys" for ever, because
        // nothing in the app ever invoked the wrap-then-promote sequence.
        let start = Self.pendingJoinerDetail(activeKeyVersion: 3)
        let roster = FakeRoster(details: [start.teamID: start])
        let joinerKeys = FakeJoinerKeys()
        let (model, _, _, _) = makeModel(detail: start, joinerKeys: joinerKeys, roster: roster)
        await model.refresh()

        let row = model.rows.first
        let joiner = row?.detail.members.first { $0.uid == "joiner" }
        XCTAssertEqual(joiner?.isPending, true, "the roster row this action exists for")
        XCTAssertTrue(model.canShareTeamKeys(row: unwrapped(row), member: unwrapped(joiner)))

        // The roster promotes the moment the envelopes land, so the fake stands
        // in for the server doing exactly that.
        let promoted = Self.detail(
            activeKeyVersion: 3,
            myRole: "admin",
            myStatus: "active",
            members: [
                TeamRosterDetail.Member(uid: "joiner", role: "member", status: "active"),
                TeamRosterDetail.Member(uid: "me", role: "admin", status: "active")
            ]
        )
        joinerKeys.probe = { @MainActor in roster.details = [promoted.teamID: promoted] }

        await model.shareTeamKeys(teamID: start.teamID, joinerUid: "joiner")

        // The RIGHT uid, and every generation the ROSTER retains — not merely
        // the active one, or the joiner is blind to the team's history, and not
        // whatever this Mac's ring happens to hold.
        XCTAssertEqual(
            joinerKeys.issues,
            [FakeJoinerKeys.Issue(
                teamID: start.teamID,
                joinerUid: "joiner",
                retainedKeyVersions: [1, 2, 3]
            )]
        )
        XCTAssertNil(model.errorMessage)
        // Refreshed afterwards: the row the admin just acted on now reads
        // `active` and no longer offers the button.
        XCTAssertEqual(
            model.rows.first?.detail.members.first { $0.uid == "joiner" }?.status,
            "active"
        )
        XCTAssertFalse(
            model.canShareTeamKeys(
                row: unwrapped(model.rows.first),
                member: unwrapped(model.rows.first?.detail.members.first { $0.uid == "joiner" })
            )
        )
        XCTAssertNil(model.sharingKeysForUID)
    }

    func test_a_non_admin_is_never_offered_the_share_keys_action() async {
        // `firestore.rules` permits a wrap addressed to ANOTHER member only for
        // an active admin, and `promoteTeamMember` refuses outright. A button
        // that could only ever be denied is worse than no button: the pending
        // state is a READ for everyone else.
        let plainMember = Self.detail(
            activeKeyVersion: 2,
            myRole: "member",
            myStatus: "active",
            members: [
                TeamRosterDetail.Member(uid: "joiner", role: "member", status: "pending"),
                TeamRosterDetail.Member(uid: "me", role: "member", status: "active")
            ]
        )
        let joinerKeys = FakeJoinerKeys()
        let (model, _, _, _) = makeModel(detail: plainMember, joinerKeys: joinerKeys)
        await model.refresh()

        let row = unwrapped(model.rows.first)
        let joiner = unwrapped(row.detail.members.first { $0.uid == "joiner" })
        XCTAssertFalse(row.detail.isAdmin)
        XCTAssertFalse(model.canShareTeamKeys(row: row, member: joiner))

        // And the model refuses even if something called it anyway: the guard
        // is in the view model, not only in the view.
        await model.shareTeamKeys(teamID: plainMember.teamID, joinerUid: "joiner")
        XCTAssertTrue(joinerKeys.issues.isEmpty)
    }

    func test_an_already_active_member_is_not_offered_the_share_keys_action() async {
        // Promotion is `pending -> active` and nothing else. Re-issuing to an
        // active member would republish immutable envelope ids and then be
        // refused by C-3 at the callable.
        let joinerKeys = FakeJoinerKeys()
        let (model, _, _, _) = makeModel(detail: Self.detail(), joinerKeys: joinerKeys)
        await model.refresh()
        let row = unwrapped(model.rows.first)
        let them = unwrapped(row.detail.members.first { $0.uid == "them" })
        XCTAssertEqual(them.status, "active")
        XCTAssertFalse(model.canShareTeamKeys(row: row, member: them))

        await model.shareTeamKeys(teamID: row.detail.teamID, joinerUid: "them")
        XCTAssertTrue(joinerKeys.issues.isEmpty)
    }

    func test_the_share_keys_action_reports_progress_while_it_runs() async {
        let start = Self.pendingJoinerDetail()
        let joinerKeys = FakeJoinerKeys()
        let (model, _, _, _) = makeModel(detail: start, joinerKeys: joinerKeys)
        await model.refresh()

        final class Seen: @unchecked Sendable {
            var uid: String?
            var loading = false
        }
        let seen = Seen()
        joinerKeys.probe = { @MainActor in
            seen.uid = model.sharingKeysForUID
            seen.loading = model.isLoading
        }

        XCTAssertNil(model.sharingKeysForUID)
        await model.shareTeamKeys(teamID: start.teamID, joinerUid: "joiner")
        // Wrapping every retained generation for every pinned device is a
        // multi-round-trip pass; a button that looks idle through it is how an
        // admin fires it three times.
        XCTAssertEqual(seen.uid, "joiner")
        XCTAssertTrue(seen.loading)
        XCTAssertNil(model.sharingKeysForUID)
    }

    func test_each_share_keys_failure_maps_to_its_own_plain_copy() {
        // A second admin's wrap already occupies an envelope id this pass needs.
        // Envelope documents are create-only, so the pass refuses rather than
        // claiming it (PR 2 review round 2, the two-admin key fork).
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                TeamVaultKeyDistributionError.envelopeAddressedElsewhere(envelopeId: "joiner_device-j_1_v2")
            ),
            .rotationConflict
        )
        // THE REAL PRODUCER, which arrived with PR 2's pre-scan (PR 4 review §5
        // hazard 6). PR 4 alone could only reach `.rotationConflict` through the
        // fallback above; the typed refusal must land on the same copy.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                TeamVaultKeyDistributionError.rotationConflict(
                    slot: "v4",
                    envelopeId: "joiner_device-j_1_v4",
                    wrappedBy: "other-admin"
                )
            ),
            .rotationConflict
        )
        // `commitGuardedByTeamState` re-read the team document and the key state
        // or the membership epoch had moved (PR 1 review N-4 / Cursor C-4).
        // Both the typed refusal and the raw `aborted` route to one case.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                TeamVaultKeyDistributionError.rosterStateMovedInFlight(
                    teamId: "team_aaaaaaaaaaaaaaaa",
                    operation: "promoteTeamMember"
                )
            ),
            .rosterStateMovedInFlight
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                Self.functionsError(.aborted, "This team's key state changed while the call was in flight.")
            ),
            .rosterStateMovedInFlight
        )
        // Coverage cannot be built at all, client-side: the distributor's own
        // typed refusals, which never cross the wire.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                TeamVaultKeyDistributionError.memberHasNoPinnedDevice(uid: "joiner")
            ),
            .joinerHasNoTrustedDevice
        )
        XCTAssertEqual(TeamJoinerKeyIssueFailure.classify(URLError(.notConnectedToInternet)), .other)
        // Each one to its own copy, and both conflict shapes to the same line:
        // they mean the same thing to an admin and have the same remedy.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.rotationConflict.message(member: "joiner"),
            TeamMemoryCopy.shareKeysConflictNotice
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.rosterStateMovedInFlight.message(member: "joiner"),
            TeamMemoryCopy.shareKeysConflictNotice
        )
        XCTAssertTrue(TeamMemoryCopy.shareKeysConflictNotice.contains("Another admin is changing this team"))
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.joinerHasNoTrustedDevice.message(member: "joiner"),
            TeamMemoryCopy.shareKeysNoTrustedDevice(member: "joiner")
        )
        // The coverage failure NAMES the joiner and says whose problem it is.
        XCTAssertTrue(
            TeamMemoryCopy.shareKeysNoTrustedDevice(member: "joiner")
                .contains("joiner has not published a trusted device yet")
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.memberNoLongerPending.message(member: "joiner"),
            TeamMemoryCopy.shareKeysNoLongerPendingNotice
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.other.message(member: "joiner"),
            TeamMemoryCopy.shareKeysFailedNotice
        )
    }

    /// Every reason the server can send, driven through the classifier.
    ///
    /// `TeamRosterReasonCode` mirrors `functions/src/teamRosterReasons.ts` in
    /// full (`scripts/ci/verify-team-roster-reason-codes.sh` and
    /// `functions/src/__tests__/teamRosterReasonCodes.test.ts` both hold the two
    /// enumerations together), so iterating `allCases` here IS the per-branch
    /// test: a new server code arrives as a new case, and this loop asserts what
    /// it renders before anybody has to think about it.
    func test_every_reason_code_routes_to_its_branch_and_an_unknown_code_falls_back() {
        // The refusals with an operator remedy. Everything else is `.other` —
        // deliberately: "Share Team Keys" publishes envelopes and promotes, so a
        // payload or caller-authority refusal on this surface is a client bug,
        // and a coverage refusal means "nothing landed, try again", which is
        // exactly what the generic notice says.
        let specific: [TeamRosterReasonCode: TeamJoinerKeyIssueFailure] = [
            .memberHasNoTrustedEscrowDevice: .joinerHasNoTrustedDevice,
            .memberNotPending: .memberNoLongerPending,
            .memberHasNotAcceptedInvite: .memberNoLongerPending,
            .memberNotFoundInTeam: .memberNoLongerPending,
            .rosterStateMovedInFlight: .rosterStateMovedInFlight
        ]
        for code in TeamRosterReasonCode.allCases {
            XCTAssertEqual(
                TeamJoinerKeyIssueFailure.classify(
                    // The STATUS CODE is deliberately the same for every case and
                    // deliberately wrong for most of them: the reason decides now,
                    // not the code and not the message.
                    Self.functionsError(.failedPrecondition, "server prose", reason: code.rawValue)
                ),
                specific[code] ?? .other,
                code.rawValue
            )
        }
        // The mirror is total, not a subset. If this number moves, a server code
        // was added or removed and the gate above should have said so first.
        // 44 at #2545, plus the two the founding slug-key recorder raises
        // (`INVALID_SLUG_KEY_ID`, `DIFFERENT_SLUG_KEY_RECORDED`) — both `.other`
        // here, because "Share Team Keys" never calls that callable.
        XCTAssertEqual(TeamRosterReasonCode.allCases.count, 46)

        // A code from a server newer than this build: ONE explicit fallback, and
        // it renders the generic copy rather than guessing at a neighbour.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                Self.functionsError(.failedPrecondition, "server prose", reason: "SOME_REFUSAL_FROM_THE_FUTURE")
            ),
            .other
        )
        // A reason that is not even a string is the same fallback, not a crash.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                NSError(
                    domain: FunctionsErrorDomain,
                    code: FunctionsErrorCode.failedPrecondition.rawValue,
                    userInfo: [FunctionsErrorDetailsKey: ["reason": 7] as NSDictionary]
                )
            ),
            .other
        )
    }

    /// THE MESSAGE IS NOT READ ANY MORE, and this is the test that would fail if
    /// somebody put the substring matching back.
    func test_the_server_message_no_longer_decides_the_copy() {
        // Both of the literals the old classifier matched, now carrying a reason
        // that CONTRADICTS them. The reason wins; the prose is inert.
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                Self.functionsError(
                    .failedPrecondition,
                    "That member has no trusted escrow device to receive team keys.",
                    reason: TeamRosterReasonCode.memberNotPending.rawValue
                )
            ),
            .memberNoLongerPending
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(
                Self.functionsError(
                    .failedPrecondition,
                    "Only a pending member can be promoted.",
                    reason: TeamRosterReasonCode.memberHasNoTrustedEscrowDevice.rawValue
                )
            ),
            .joinerHasNoTrustedDevice
        )
        // And with NO reason at all, the same two messages are `.other`. That is
        // the deletion: a `failed-precondition` whose cause this client cannot
        // identify gets generic-but-true copy, never specific-and-possibly-wrong.
        // It is also what a Mac talking to a backend older than
        // `functions/src/teamRosterReasons.ts` sees.
        for prose in [
            "That member has no trusted escrow device to receive team keys.",
            "Only a pending member can be promoted.",
            "Key envelope coverage is incomplete: 3 envelope(s) were not supplied.",
            "Team roster is missing its key state."
        ] {
            XCTAssertEqual(
                TeamJoinerKeyIssueFailure.classify(Self.functionsError(.failedPrecondition, prose)),
                .other,
                prose
            )
        }
        // Two status codes still carry meaning on their own when no reason is
        // attached, and they were never message matching: `aborted` has exactly
        // one producer in this lane, and a missing row means the same thing to an
        // admin as "not pending".
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(Self.functionsError(.aborted, "prose")),
            .rosterStateMovedInFlight
        )
        XCTAssertEqual(
            TeamJoinerKeyIssueFailure.classify(Self.functionsError(.notFound, "prose")),
            .memberNoLongerPending
        )
        // An error from outside the Functions domain carries no reason and no
        // meaning here.
        XCTAssertEqual(TeamJoinerKeyIssueFailure.classify(URLError(.timedOut)), .other)
    }

    func test_a_failed_share_reaches_the_member_as_copy_and_never_as_the_raw_error() async {
        let start = Self.pendingJoinerDetail()
        let joinerKeys = FakeJoinerKeys()
        joinerKeys.error = Self.functionsError(
            .failedPrecondition,
            // A real callable message, carrying a real identifier. It is no
            // longer classified either — the reason below is — but it is still
            // the thing that must never reach the screen.
            "That member has no trusted escrow device to receive team keys. (joiner@example.com)",
            reason: TeamRosterReasonCode.memberHasNoTrustedEscrowDevice.rawValue
        )
        let (model, _, _, _) = makeModel(detail: start, joinerKeys: joinerKeys)
        await model.refresh()
        await model.shareTeamKeys(teamID: start.teamID, joinerUid: "joiner")

        XCTAssertEqual(model.errorMessage, TeamMemoryCopy.shareKeysNoTrustedDevice(member: "joiner"))
        XCTAssertFalse(model.errorMessage?.contains("joiner@example.com") ?? true)
        XCTAssertNil(model.sharingKeysForUID)
        // The button comes back: nothing was promoted, so the pass is retryable.
        XCTAssertTrue(
            model.canShareTeamKeys(
                row: unwrapped(model.rows.first),
                member: unwrapped(model.rows.first?.detail.members.first { $0.uid == "joiner" })
            )
        )
    }

    /// `XCTUnwrap` throws, and these assertions read better inline than behind a
    /// `try` on every line in a non-throwing `async` test.
    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("unexpected nil", file: file, line: line)
            fatalError("unexpected nil")
        }
        return value
    }

    // MARK: Rotation status

    func test_the_completion_note_counts_only_for_the_active_generation() {
        // The roster advances `activeKeyVersion` BEFORE a single fact is
        // re-sealed, so a completion note for generation 1 says nothing about
        // generation 2. Reading it as "done" is the exact confusion PR 2 review
        // N1 exists to stop.
        let stale = Self.detail(activeKeyVersion: 2, rewrapCompletedKeyVersion: 1)
        XCTAssertFalse(stale.isRewrapComplete)
        XCTAssertEqual(
            TeamMemorySectionModel.rotationStatusLines(for: stale).last,
            TeamMemoryCopy.rewrapIncomplete(keyVersion: 2)
        )

        let current = Self.detail(activeKeyVersion: 2, rewrapCompletedKeyVersion: 2)
        XCTAssertTrue(current.isRewrapComplete)
        XCTAssertEqual(
            TeamMemorySectionModel.rotationStatusLines(for: current).last,
            TeamMemoryCopy.rewrapComplete(keyVersion: 2)
        )
    }

    func test_one_teams_rotation_progress_never_renders_under_another_team() async {
        // PR 4 review M3. An admin of two teams presses "Rotate Key Now" on A;
        // the pass reports 812 of 4,010. Team B's card must not repeat those
        // numbers — they are a claim about a corpus nothing touched, which is
        // the same class of false progress claim PR 2 review N1 exists to stop,
        // arriving through the UI instead of the roster.
        let teamA = Self.detail(teamID: "team_aaaaaaaaaaaaaaaa", activeKeyVersion: 2)
        let teamB = Self.detail(teamID: "team_bbbbbbbbbbbbbbbb", activeKeyVersion: 2)
        let directory = FakeDirectory()
        directory.remember(teamID: teamB.teamID)
        let roster = FakeRoster(details: [teamA.teamID: teamA, teamB.teamID: teamB])
        let rotator = FakeRotator(
            progress: TeamCloudVaultRewrapProgress(
                scannedDocuments: 4010,
                rewrappedDocuments: 812,
                skippedDocuments: 3198
            )
        )
        let model = TeamMemorySectionModel(
            directory: directory,
            roster: roster,
            admin: FakeAdmin(),
            rotator: rotator,
            uidProvider: { "me" },
            personalGateProvider: { true },
            remoteConfigProvider: { (true, true) },
            optInProvider: { [] },
            optInWriter: { _ in }
        )
        directory.remember(teamID: teamA.teamID)
        await model.refresh()
        XCTAssertEqual(model.rows.count, 2)

        await model.rotateKey(teamID: teamA.teamID)
        XCTAssertEqual(rotator.rotated, [teamA.teamID])

        let progressLine = TeamMemoryCopy.rewrapProgress(resealed: 812, scanned: 4010)
        let linesA = TeamMemorySectionModel.rotationStatusLines(
            for: teamA,
            progress: model.rotationProgress(forTeamID: teamA.teamID)
        )
        let linesB = TeamMemorySectionModel.rotationStatusLines(
            for: teamB,
            progress: model.rotationProgress(forTeamID: teamB.teamID)
        )
        XCTAssertTrue(linesA.contains(progressLine), "the team that was rotated reports its counters")
        XCTAssertNil(model.rotationProgress(forTeamID: teamB.teamID))
        XCTAssertFalse(linesB.contains(progressLine), "a team nothing touched claims no re-sealing")
        // The per-team roster-derived line is still right on BOTH rows: the bug
        // was the counters, not the completion state.
        XCTAssertTrue(linesB.contains(TeamMemoryCopy.rewrapIncomplete(keyVersion: 2)))
    }

    func test_a_rotation_conflict_offers_the_real_recovery_and_burns_the_generation_it_named() async {
        // PR 4 review §5 hazards 5 and 6. `rotationConflict` means another
        // admin's wraps already occupy the envelope ids of the generation this
        // Mac minted — and envelope documents are create-only, so retrying THAT
        // generation can never work. The row has to offer the one thing that
        // can: burn it on the roster and rotate past it.
        let teamA = Self.detail(teamID: "team_aaaaaaaaaaaaaaaa", activeKeyVersion: 3)
        let teamB = Self.detail(teamID: "team_bbbbbbbbbbbbbbbb", activeKeyVersion: 3)
        let directory = FakeDirectory()
        directory.remember(teamID: teamA.teamID)
        directory.remember(teamID: teamB.teamID)
        let roster = FakeRoster(details: [teamA.teamID: teamA, teamB.teamID: teamB])
        let rotator = FakeRotator(
            progress: TeamCloudVaultRewrapProgress(
                scannedDocuments: 10,
                rewrappedDocuments: 10,
                skippedDocuments: 0
            )
        )
        rotator.failNextRotation(
            with: TeamVaultKeyDistributionError.rotationConflict(
                slot: "v4",
                envelopeId: "env-1",
                wrappedBy: "other-admin"
            )
        )
        let model = TeamMemorySectionModel(
            directory: directory,
            roster: roster,
            admin: FakeAdmin(),
            rotator: rotator,
            uidProvider: { "me" },
            personalGateProvider: { true },
            remoteConfigProvider: { (true, true) },
            optInProvider: { [] },
            optInWriter: { _ in }
        )
        await model.refresh()

        await model.rotateKey(teamID: teamA.teamID)

        // The generation is named, not guessed: the recovery burns exactly the
        // version the refusal carried.
        XCTAssertEqual(model.rotationConflictVersion(forTeamID: teamA.teamID), 4)
        // And it belongs to the team it happened on — same keying discipline as
        // the progress counters (M3).
        XCTAssertNil(model.rotationConflictVersion(forTeamID: teamB.teamID))
        XCTAssertEqual(
            model.errorMessage,
            TeamMemoryCopy.rotationConflictNotice,
            "the conflict gets its own copy, never the generic team-action failure"
        )
        XCTAssertTrue(rotator.abandoned.isEmpty, "nothing is burned until the admin presses the recovery")

        await model.abandonConflictingGenerationAndRotate(teamID: teamA.teamID)

        XCTAssertEqual(
            rotator.abandoned,
            [
                FakeRotator.Abandonment(
                    teamID: teamA.teamID,
                    conflictingVersion: 4,
                    activeKeyVersion: 3,
                    burnedKeyVersions: [],
                    activeMemberUids: ["me", "them"]
                )
            ]
        )
        XCTAssertNil(model.rotationConflictVersion(forTeamID: teamA.teamID), "a recovered team stops offering it")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.rotationProgress(forTeamID: teamA.teamID))
    }

    func test_the_recovery_is_offered_only_after_a_conflict_and_only_for_that_team() async {
        // Burning a generation is an irreversible roster write. It must not be
        // reachable by habit: a team that never conflicted has no version to
        // burn, and pressing the action does nothing at all.
        let team = Self.detail(activeKeyVersion: 3)
        let directory = FakeDirectory()
        directory.remember(teamID: team.teamID)
        let rotator = FakeRotator(
            progress: TeamCloudVaultRewrapProgress(scannedDocuments: 1, rewrappedDocuments: 1, skippedDocuments: 0)
        )
        let model = TeamMemorySectionModel(
            directory: directory,
            roster: FakeRoster(details: [team.teamID: team]),
            admin: FakeAdmin(),
            rotator: rotator,
            uidProvider: { "me" },
            personalGateProvider: { true },
            remoteConfigProvider: { (true, true) },
            optInProvider: { [] },
            optInWriter: { _ in }
        )
        await model.refresh()

        XCTAssertNil(model.rotationConflictVersion(forTeamID: team.teamID))
        await model.abandonConflictingGenerationAndRotate(teamID: team.teamID)
        XCTAssertTrue(rotator.abandoned.isEmpty, "no conflict, no burn")

        // A rotation that merely FAILED is retried, never burned.
        rotator.failNextRotation(with: Self.functionsError(.unavailable, "backend unavailable"))
        await model.rotateKey(teamID: team.teamID)
        XCTAssertNil(model.rotationConflictVersion(forTeamID: team.teamID))
        XCTAssertEqual(model.errorMessage, TeamMemorySectionModel.message(for: NSError(domain: "x", code: 0)))
        await model.abandonConflictingGenerationAndRotate(teamID: team.teamID)
        XCTAssertTrue(rotator.abandoned.isEmpty)
    }

    func test_a_rotation_reads_the_burned_list_from_the_roster_not_from_this_mac() async {
        // PR 4 review §5 hazard 11. Once a generation is burned the roster
        // authority refuses `activeKeyVersion + 1` outright, so the client that
        // picks the version it is about to mint has to be handed the roster's
        // burned list. Proving it reaches the seam is what keeps
        // `nextRotatableKeyVersion` computing the number the server will accept.
        let team = Self.detail(activeKeyVersion: 3, burnedKeyVersions: [4])
        let directory = FakeDirectory()
        directory.remember(teamID: team.teamID)
        let rotator = FakeRotator(
            progress: TeamCloudVaultRewrapProgress(scannedDocuments: 1, rewrappedDocuments: 1, skippedDocuments: 0)
        )
        let model = TeamMemorySectionModel(
            directory: directory,
            roster: FakeRoster(details: [team.teamID: team]),
            admin: FakeAdmin(),
            rotator: rotator,
            uidProvider: { "me" },
            personalGateProvider: { true },
            remoteConfigProvider: { (true, true) },
            optInProvider: { [] },
            optInWriter: { _ in }
        )
        await model.refresh()

        await model.rotateKey(teamID: team.teamID)
        XCTAssertEqual(rotator.rotatedWithBurned, [[4]])
    }

    func test_the_share_keys_in_flight_label_belongs_to_the_team_it_was_started_on() async {
        // The same defect class as M3: one person can be a pending member of two
        // teams under one uid, so "Sharing team keys…" keyed by uid alone would
        // light up a row in a team this admin never pressed anything on.
        let pendingA = Self.pendingJoinerDetail()
        let pendingB = TeamRosterDetail(
            teamID: "team_bbbbbbbbbbbbbbbb",
            name: "Platform",
            activeKeyVersion: 3,
            retainedKeyVersions: [1, 2, 3],
            burnedKeyVersions: [],
            slugKeyRecorded: true,
            keyRotationRequired: false,
            rewrapCompletedKeyVersion: nil,
            rewrapJobId: nil,
            myRole: "admin",
            myStatus: "active",
            members: [
                TeamRosterDetail.Member(uid: "joiner", role: "member", status: "pending"),
                TeamRosterDetail.Member(uid: "me", role: "admin", status: "active")
            ]
        )
        let directory = FakeDirectory()
        directory.remember(teamID: pendingB.teamID)
        let roster = FakeRoster(details: [pendingA.teamID: pendingA, pendingB.teamID: pendingB])
        let joinerKeys = FakeJoinerKeys()
        let (model, _, _, _) = makeModel(
            detail: pendingA,
            directory: directory,
            joinerKeys: joinerKeys,
            roster: roster
        )
        await model.refresh()

        final class Seen: @unchecked Sendable {
            var onA = false
            var onB = false
        }
        let seen = Seen()
        joinerKeys.probe = { @MainActor in
            seen.onA = model.isSharingKeys(teamID: pendingA.teamID, uid: "joiner")
            seen.onB = model.isSharingKeys(teamID: pendingB.teamID, uid: "joiner")
        }

        await model.shareTeamKeys(teamID: pendingA.teamID, joinerUid: "joiner")
        XCTAssertTrue(seen.onA, "the row the admin pressed says it is working")
        XCTAssertFalse(seen.onB, "the same uid on another team says nothing")
        XCTAssertFalse(model.isSharingKeys(teamID: pendingA.teamID, uid: "joiner"))
    }

    func test_the_rotation_status_reports_skipped_documents_rather_than_dropping_them() {
        let lines = TeamMemorySectionModel.rotationStatusLines(
            for: Self.detail(activeKeyVersion: 2, keyRotationRequired: true, rewrapCompletedKeyVersion: nil),
            progress: TeamCloudVaultRewrapProgress(
                scannedDocuments: 4010,
                rewrappedDocuments: 812,
                skippedDocuments: 3198
            )
        )
        XCTAssertTrue(lines.contains(TeamMemoryCopy.rotationRequiredNotice))
        // BOTH numbers. "812 re-sealed" alone reads exactly like a finished
        // rotation, which is what it is not.
        XCTAssertTrue(lines.contains(TeamMemoryCopy.rewrapProgress(resealed: 812, scanned: 4010)))
        XCTAssertTrue(lines.contains(TeamMemoryCopy.rewrapIncomplete(keyVersion: 2)))
    }

    // MARK: - Creating a team mints its keys (D16 wiring)

    /// **The gap this pins.** `createTeam` used to call the callable, remember
    /// the id and stop: `TeamVaultKeyDistributor.bootstrapTeamKeys` — the method
    /// that generates `teamVaultKey_v1` and the non-rotating `teamSlugKey` and
    /// publishes the founder's own envelopes — had no production caller anywhere.
    /// Every team the shipped app created therefore had no keys at all, on any
    /// Mac, for ever: the sync cycle parked on a missing slug key and "Share Team
    /// Keys" failed `missingKeyForSlot` because the ADMIN's own ring was empty.
    func test_creating_a_team_mints_and_publishes_its_founding_keys() async {
        let founderKeys = FakeFounderKeys()
        let (model, admin, directory, _) = makeModel(
            detail: Self.detail(),
            founderKeys: founderKeys,
            keyReadiness: .ready
        )
        admin.newTeamID = "team_bbbbbbbbbbbbbbbb"

        await model.createTeam(named: "Platform")

        XCTAssertEqual(admin.created, ["Platform"])
        XCTAssertEqual(
            founderKeys.teamIDs,
            ["team_bbbbbbbbbbbbbbbb"],
            "the founding keys are minted for the id the callable just returned"
        )
        XCTAssertTrue(
            directory.knownTeamIDs().contains("team_bbbbbbbbbbbbbbbb"),
            "and the id is remembered: there is no 'list my teams' query, so losing it strands the team"
        )
        XCTAssertNil(model.errorMessage)
    }

    /// A bootstrap that fails must leave a RECOVERABLE state, not a team with no
    /// keys and no way back: the team is real on the server, so the copy says so
    /// and the row offers the resume rather than inviting a second `createTeam`.
    func test_a_founding_that_did_not_publish_is_reported_honestly_and_can_be_resumed() async throws {
        let founderKeys = FakeFounderKeys()
        founderKeys.error = TeamMemorySectionModelTestError.refused
        let (model, admin, directory, _) = makeModel(
            detail: Self.detail(),
            founderKeys: founderKeys,
            // What the ring looks like after an interrupted bootstrap: both
            // slots minted PENDING, neither published.
            keyReadiness: .setupIncomplete
        )
        admin.newTeamID = Self.detail().teamID

        await model.createTeam(named: "Platform")

        XCTAssertEqual(
            model.errorMessage,
            TeamMemoryCopy.teamCreatedWithoutKeysNotice,
            "never the generic 'that team action did not complete' — the team DID land"
        )
        XCTAssertTrue(directory.knownTeamIDs().contains(Self.detail().teamID))
        let row = model.rows.first
        XCTAssertEqual(row?.keyReadiness, .setupIncomplete)
        XCTAssertEqual(row?.keyReadiness.notice, TeamMemoryCopy.keysSetupIncompleteNotice)
        XCTAssertTrue(model.canFinishTeamSetup(row: try XCTUnwrap(row)))

        // The resume is a plain retry of the same idempotent bootstrap.
        founderKeys.error = nil
        await model.finishTeamSetup(teamID: Self.detail().teamID)
        XCTAssertEqual(
            founderKeys.teamIDs,
            [Self.detail().teamID, Self.detail().teamID],
            "the same team, bootstrapped again — the pending ring is what keeps it the same KEYS"
        )
        XCTAssertNil(model.errorMessage)
    }

    /// The one refusal with a different remedy gets different copy. Telling a
    /// member whose other Mac founded the team to "try again" would be telling
    /// them to press a button that refuses for ever.
    func test_a_founding_another_mac_published_gets_its_own_copy() async {
        let founderKeys = FakeFounderKeys()
        founderKeys.error = TeamFounderKeyBootstrapError.keysMintedOnAnotherDevice(teamID: Self.detail().teamID)
        let (model, _, _, _) = makeModel(
            detail: Self.detail(),
            founderKeys: founderKeys,
            keyReadiness: .awaitingKeys
        )
        await model.refresh()

        await model.finishTeamSetup(teamID: Self.detail().teamID)

        XCTAssertEqual(model.errorMessage, TeamMemoryCopy.keysFoundedOnAnotherDeviceNotice)
        XCTAssertNotEqual(model.errorMessage, TeamMemoryCopy.finishTeamSetupFailedNotice)
    }

    /// A non-admin is never offered the founding action: the rules confine a
    /// wrap of a generation nobody has published to an admin, so the button
    /// would only ever be denied.
    func test_only_an_admin_is_offered_the_founding_action() async throws {
        let founderKeys = FakeFounderKeys()
        let (model, _, _, _) = makeModel(
            detail: Self.detail(myRole: "member"),
            founderKeys: founderKeys,
            keyReadiness: .awaitingKeys
        )
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first)

        XCTAssertFalse(model.canFinishTeamSetup(row: row))
        await model.finishTeamSetup(teamID: row.detail.teamID)
        XCTAssertTrue(founderKeys.teamIDs.isEmpty, "and pressing it anyway reaches nothing")
    }

    /// The three states a member can be in, and the one non-state a build with
    /// no ring reports.
    ///
    /// `ready` requires BOTH keys. The slug key NAMES documents and the active
    /// generation SEALS them; a Mac holding one of them syncs nothing, and
    /// saying "ready" there is exactly the silence this change is about.
    func test_the_key_readiness_states_are_resolved_from_the_ring_not_the_roster() {
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: true,
                holdsActiveVaultKey: true,
                hasPendingFoundingMint: false,
                rosterRecordedSlugKey: true
            ),
            .ready
        )
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: true,
                holdsActiveVaultKey: false,
                hasPendingFoundingMint: false,
                rosterRecordedSlugKey: true
            ),
            .awaitingKeys,
            "the slug key alone names documents it cannot seal"
        )
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: false,
                holdsActiveVaultKey: true,
                hasPendingFoundingMint: false,
                rosterRecordedSlugKey: true
            ),
            .awaitingKeys
        )
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: false,
                holdsActiveVaultKey: false,
                hasPendingFoundingMint: true,
                rosterRecordedSlugKey: true
            ),
            .setupIncomplete,
            "a pending founding mint is this Mac's own interrupted bootstrap"
        )
        // A published ring wins over a leftover pending slot: the slots are
        // promoted, not deleted, so a resumed bootstrap leaves both behind.
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: true,
                holdsActiveVaultKey: true,
                hasPendingFoundingMint: true,
                rosterRecordedSlugKey: true
            ),
            .ready
        )
        // THE STATE THE FOUNDER CANNOT SEE FROM THEIR OWN SYNC. This Mac holds
        // everything and the roster has no `slugKeyId`, so the B6 rule lands
        // every joiner's slug envelope in the PENDING ring and nobody else can
        // derive a document id. The founder syncs perfectly; the team is dead.
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                holdsSlugKey: true,
                holdsActiveVaultKey: true,
                hasPendingFoundingMint: false,
                rosterRecordedSlugKey: false
            ),
            .founderRecordNotPublished
        )
        XCTAssertEqual(
            TeamKeyReadiness.founderRecordNotPublished.notice,
            TeamMemoryCopy.slugKeyNotRecordedNotice
        )
        XCTAssertNil(TeamKeyReadiness.unknown.notice, "a build with no ring says nothing rather than guessing")
        XCTAssertEqual(TeamKeyReadiness.ready.notice, TeamMemoryCopy.keysReadyNotice)
        XCTAssertEqual(TeamKeyReadiness.awaitingKeys.notice, TeamMemoryCopy.keysAwaitingAdminNotice)
    }

    /// The real ring reading, over the same in-memory double the distributor
    /// tests use — so the closure the production wiring passes is exercised
    /// rather than assumed.
    func test_the_readiness_reading_uses_the_active_generation_the_roster_names() throws {
        let ring = InMemoryTeamVaultKeyRing()
        let recorded = Self.detail(activeKeyVersion: 2, slugKeyRecorded: true)
        let teamID = recorded.teamID
        let keyBytes = Data(repeating: 0x7A, count: 32)
        XCTAssertEqual(TeamKeyReadiness.resolve(ring: ring, detail: recorded), .awaitingKeys)
        try ring.storePending(keyBytes, teamId: teamID, slot: .slug)
        XCTAssertEqual(TeamKeyReadiness.resolve(ring: ring, detail: recorded), .setupIncomplete)
        try ring.store(keyBytes, teamId: teamID, slot: .slug)
        try ring.store(keyBytes, teamId: teamID, slot: .vault(version: 1))
        XCTAssertEqual(
            TeamKeyReadiness.resolve(ring: ring, detail: recorded),
            .setupIncomplete,
            "holding v1 while the team seals under v2 is not ready — the rules refuse every write"
        )
        try ring.store(keyBytes, teamId: teamID, slot: .vault(version: 2))
        XCTAssertEqual(TeamKeyReadiness.resolve(ring: ring, detail: recorded), .ready)
        // Same ring, same Mac, and the TEAM's founding is unfinished.
        XCTAssertEqual(
            TeamKeyReadiness.resolve(
                ring: ring,
                detail: Self.detail(activeKeyVersion: 2, slugKeyRecorded: false)
            ),
            .founderRecordNotPublished
        )
    }

    /// An admin whose own Mac is fully keyed is still offered the founding
    /// action while the roster has no `slugKeyId` — because from where they sit
    /// nothing looks wrong, and every member they admit gets a dead team.
    func test_an_unrecorded_slug_key_still_offers_the_founding_action() async throws {
        let founderKeys = FakeFounderKeys()
        let (model, _, _, _) = makeModel(
            detail: Self.detail(slugKeyRecorded: false),
            founderKeys: founderKeys,
            keyReadiness: .founderRecordNotPublished
        )
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first)

        XCTAssertEqual(row.keyReadiness, .founderRecordNotPublished)
        XCTAssertTrue(model.canFinishTeamSetup(row: row))
        await model.finishTeamSetup(teamID: row.detail.teamID)
        XCTAssertEqual(founderKeys.teamIDs, [row.detail.teamID])
    }

    /// A founding that threw this Mac's own minted keys away SAYS SO (D16
    /// bootstrap-wiring ruling, clause 4).
    ///
    /// The pass succeeded — the team's real keys arrived from its published
    /// envelopes and this Mac kept those — but the member pressed a button that
    /// makes keys and the keys it made are gone. Reporting nothing would leave
    /// them believing the keys on this Mac are the ones they just created, and
    /// the one wrong reaction is to press it again.
    func test_a_founding_that_discarded_this_macs_mint_reports_it() async throws {
        let founderKeys = FakeFounderKeys()
        founderKeys.discardedLocalMintSlots = [.vault(version: 1), .slug]
        let (model, _, _, _) = makeModel(
            detail: Self.detail(),
            founderKeys: founderKeys,
            keyReadiness: .setupIncomplete
        )
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first)

        await model.finishTeamSetup(teamID: row.detail.teamID)

        XCTAssertEqual(
            model.errorMessage,
            TeamMemoryCopy.foundingMintDiscardedNotice,
            "the discard is disclosed, not swallowed as a plain success"
        )
    }

    /// And the ordinary founding stays silent: a notice on every press would
    /// train the founder to ignore the one press that matters.
    func test_a_founding_that_discarded_nothing_says_nothing() async throws {
        let founderKeys = FakeFounderKeys()
        let (model, _, _, _) = makeModel(
            detail: Self.detail(),
            founderKeys: founderKeys,
            keyReadiness: .setupIncomplete
        )
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first)

        await model.finishTeamSetup(teamID: row.detail.teamID)

        XCTAssertNil(model.errorMessage)
    }
}
