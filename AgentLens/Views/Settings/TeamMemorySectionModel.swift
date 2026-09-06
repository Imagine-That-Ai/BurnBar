import Foundation
import Observation

// MARK: - Team memory Settings section, view model (memory program D16 / P22, PR 4)
//
// The section is a READER of a server-owned roster plus a WRITER of exactly one
// local thing: the per-team consent lever. Every membership mutation goes to a
// callable, because `firestore.rules` denies every client write to
// `team_rosters/**` — there is no optimistic local roster edit to make, and this
// model deliberately offers none. What it caches locally is a list of team ids
// this Mac has been told about, which is navigation state, not authority: the
// roster answers "am I a member", every cycle, for the rules and for this view
// alike.

/// The team ids this Mac knows to ask the roster about.
///
/// WHY THIS EXISTS AT ALL. There is no "list my teams" query: `team_rosters` is
/// readable only by a member of the named team, and the `members` rule is
/// path-scoped under `team_rosters/{teamId}`, so a `collectionGroup("members")`
/// query — which would need a `match /{path=**}/members/{memberUid}` rule — is
/// denied. A client therefore cannot enumerate its own memberships; it can only
/// remember the ids it was given when it created or joined a team. That is a
/// navigation cache and nothing more: it grants no access, and a stale entry
/// resolves to "not a member" the moment the roster is read.
protocol TeamMembershipDirectory: Sendable {
    func knownTeamIDs() -> [String]
    func remember(teamID: String)
    func forget(teamID: String)
}

/// `UserDefaults`, deliberately, not the Keychain and not `MemorySettings`.
/// A team id is a public identifier the server already holds, and it is not
/// consent — consent is `MemorySettings.teamMemorySyncEnabled`, which is what
/// the sync lane reads and what `TeamMemorySyncGate` ANDs. Keeping the two apart
/// means forgetting a team here can never silently opt a member back in there.
struct UserDefaultsTeamMembershipDirectory: TeamMembershipDirectory {
    static let storageKey = "memoryTeamKnownTeamIDsJSON"
    var defaults: UserDefaults = .standard

    func knownTeamIDs() -> [String] {
        guard let json = defaults.string(forKey: Self.storageKey),
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data).filter { !$0.isEmpty }.sorted()
        } catch {
            // A malformed cache degrades to "no teams listed", never to a throw
            // at launch. The member can re-join with their invite token.
            return []
        }
    }

    func remember(teamID: String) {
        write(Set(knownTeamIDs()).union([teamID]))
    }

    func forget(teamID: String) {
        write(Set(knownTeamIDs()).subtracting([teamID]))
    }

    private func write(_ ids: Set<String>) {
        do {
            let data = try JSONEncoder().encode(ids.sorted())
            defaults.set(String(data: data, encoding: .utf8) ?? "[]", forKey: Self.storageKey)
        } catch {
            // `[String]` cannot fail to encode, so this branch is unreachable in
            // practice — but "unreachable" is a claim, and a silent one is how a
            // team quietly stops being listed. Leave the previous value and say
            // so; the roster, not this cache, is the authority either way.
            AppLogger.dataStore.silentFailure("team membership directory write", error: error)
        }
    }
}

/// One team as the roster describes it, plus this member's own row.
struct TeamRosterDetail: Equatable, Sendable {
    struct Member: Equatable, Sendable, Identifiable {
        let uid: String
        let role: String
        let status: String
        var id: String { uid }
        var isAdmin: Bool { role == "admin" }
        var isActive: Bool { status == "active" }
        /// Accepted the invite, not yet issued their key envelopes. This is the
        /// only status an admin can act on with "Share Team Keys".
        var isPending: Bool { status == "pending" }
    }

    let teamID: String
    let name: String
    let activeKeyVersion: Int
    let retainedKeyVersions: [Int]
    /// Generations an admin minted, published envelopes for, and abandoned
    /// before `rotateTeamKey` recorded them (PR 2's escape hatch). Mirrored
    /// here because the CLIENT picks the version it is about to mint, and
    /// `activeKeyVersion + 1` is refused outright once one is burned.
    ///
    /// `membershipEpoch` is deliberately NOT mirrored: it is a conflict-detection
    /// read the roster authority performs inside its own transaction, and a
    /// client copy of it would be a number this section could only render or
    /// misuse.
    let burnedKeyVersions: [Int]
    let keyRotationRequired: Bool
    /// The rotation-completion note, promoted from PR 2's local `UserDefaults`
    /// note to a roster field written by `recordTeamRewrapComplete` (PR 2 review
    /// N1). Every member sees it, not only the admin who ran the pass.
    let rewrapCompletedKeyVersion: Int?
    let rewrapJobId: String?
    /// This member's own row. `nil` means the roster has no row at all, which is
    /// what a stale local team id looks like.
    let myRole: String?
    let myStatus: String?
    let members: [Member]

    var isMemberActive: Bool { myStatus == "active" }
    var isMemberPending: Bool { myStatus == "pending" }
    var isAdmin: Bool { myRole == "admin" && isMemberActive }
    /// A rotation is only finished when the re-seal pass covered the generation
    /// the roster is now pinned to. A note for an older generation is a note
    /// about an older rotation.
    var isRewrapComplete: Bool { rewrapCompletedKeyVersion == activeKeyVersion }
}

/// Reads `team_rosters/{teamId}` and its `members` subcollection. A seam because
/// a unit test cannot drive Firestore, and because this is the one input to the
/// section the client does not own.
protocol TeamRosterDirectoryReading: Sendable {
    func rosterDetail(teamID: String, uid: String) async throws -> TeamRosterDetail?
}

/// The membership mutations the section offers. Every one is a callable: the
/// rules deny client writes to `team_rosters/**` outright, so there is no
/// "optimistic" path to get wrong.
protocol TeamMemoryAdministering: Sendable {
    func createTeam(name: String) async throws -> String
    func acceptInvite(teamID: String, inviteToken: String) async throws
    func inviteMember(teamID: String, email: String, role: String) async throws -> String
    func removeMember(teamID: String, targetUid: String) async throws
}

/// "Rotate now". NOT a callable the section may reach on its own: a rotation has
/// to mint `v(N+1)`, wrap it for every remaining active member's pinned devices,
/// call `rotateTeamKey` (which verifies that coverage) and only then re-seal the
/// corpus. Calling the callable without the wraps is how every remaining member
/// ends up active-but-blind, which is exactly what PR 1's coverage check refuses
/// — so the whole sequence lives behind this seam, in
/// `TeamVaultKeyDistributor.rotateTeamKey`.
protocol TeamKeyRotating: Sendable {
    func rotate(
        teamID: String,
        activeKeyVersion: Int,
        burnedKeyVersions: [Int],
        activeMemberUids: [String]
    ) async throws -> TeamCloudVaultRewrapProgress

    /// The recovery from ``TeamVaultKeyDistributionError/rotationConflict(slot:envelopeId:wrappedBy:)``,
    /// and the reason that error is not simply "try again".
    ///
    /// A conflict means another admin's Mac already published envelopes for the
    /// generation this Mac was minting, wrapping a key only THEY hold. Envelope
    /// documents are create-only, so those ids are occupied forever and no retry
    /// of that generation can ever succeed. The only way past it is to have the
    /// roster authority record the generation in `burnedKeyVersions` — after
    /// which `rotateTeamKey`'s next-version rule steps over it — and mint the
    /// one after. That is `TeamVaultKeyDistributor.abandonConflictingGenerationAndRotate`,
    /// and it is idempotent: a second press burns the same generation and
    /// nothing else, so an interrupted attempt resumes at the rotation rather
    /// than spending another version.
    ///
    /// BEHIND A DELIBERATE PRESS, never automatic. Burning a generation is a
    /// roster-visible, irreversible write, and the honest reading of a conflict
    /// is "the other admin may still be mid-pass" — so the section says both and
    /// lets the admin decide.
    func abandonConflictingGenerationAndRotate(
        teamID: String,
        conflictingVersion: Int,
        activeKeyVersion: Int,
        burnedKeyVersions: [Int],
        activeMemberUids: [String]
    ) async throws -> TeamCloudVaultRewrapProgress
}

/// "Share team keys" — the join half of design §3(b)2, and for the same reason
/// `TeamKeyRotating` exists: it is a SEQUENCE, not a callable.
///
/// An active admin's client enumerates the roster's `retainedKeyVersions`,
/// seals every one of them PLUS the non-rotating slug key to each device the
/// joiner's roster row pins, publishes those envelopes, and only then calls
/// `promoteTeamMember`, which verifies coverage before flipping `pending ->
/// active`. That order is what makes Semantic A true rather than aspirational:
/// a member is never active-but-blind, and a joiner who could sync but not
/// decrypt the history would be exactly that.
///
/// MANUAL, NOT AUTOMATIC, and deliberately so. Promotion grants the joiner the
/// team's entire history in one irreversible step (the envelopes are create-only
/// and the keys they carry cannot be recalled), so it is an admission decision
/// an admin takes, not a side effect of an admin's Mac happening to sync. Doing
/// it in the background would also make admission a race between admin Macs:
/// envelope documents are create-only, so two admins wrapping the same joiner
/// concurrently is the `rotationConflict` shape PR 2 refuses rather than claims.
///
/// A THIRD REASON NOW HOLDS TOO (PR 4 review L8, closed by PR 2's C-4 round).
/// `membershipEpoch` is seeded by `createTeam`, bumped by every callable that
/// changes the ACTIVE member set, and guarded by `commitGuardedByTeamState` — so
/// a promotion landing mid-rotation aborts that rotation instead of publishing a
/// generation the new member holds no wrap for. `recordTeamRewrapComplete`
/// commits under the same guard. The two reasons above never depended on it and
/// still stand on their own; the epoch is what makes the race a refusal rather
/// than a silently wrong commit.
protocol TeamJoinerKeyIssuing: Sendable {
    func issueKeys(teamID: String, joinerUid: String, retainedKeyVersions: [Int]) async throws
}

// MARK: - The gate the toggle shows

/// Why the per-team switch is unavailable, in the member's terms.
///
/// The switch never silently reads available while the lane above it is shut,
/// and it says which lever is shut — a greyed control with no explanation is how
/// a member concludes the app is broken.
///
/// WHAT `personalGateOpen` ACTUALLY IS (PR 4 review L4). It is
/// `MemoryDeviceSyncScope.current(...).isOpen`: the four personal memory levers
/// (`SettingsManager.memoryDeviceSyncEnabled` — the sub-toggle AND the backup
/// opt-in AND the live Data Vault entitlement AND the fleet ceiling) ANDed with
/// the ACCOUNT levers every sync domain honours (Firebase available, signed in,
/// account cloud sync on). That is `TeamMemorySyncGate`'s `deviceSyncGateOpen`
/// AND its `accountLeversOpen` in one value, so the row cannot read available
/// while `TeamMemorySyncDomain.runCycle` would return `.idle`. The one lever
/// this enum does NOT model is the team opt-in itself, which is the switch.
enum TeamMemoryToggleAvailability: Equatable {
    case available
    case personalGateClosed
    case fleetCeilingClosed
    case pendingJoin
    case notAMember

    var isAvailable: Bool { self == .available }

    var explanation: String? {
        switch self {
        case .available: nil
        case .personalGateClosed: TeamMemoryCopy.personalGateClosedNotice
        case .fleetCeilingClosed: TeamMemoryCopy.remoteConfigClosedNotice
        case .pendingJoin: TeamMemoryCopy.pendingJoinNotice
        case .notAMember: TeamMemoryCopy.emptyTeamsNotice
        }
    }

    /// Pure, and ordered from the outermost lever inward, so the reason a member
    /// reads is the one they can actually act on: fixing the fleet ceiling is not
    /// something they can do, but turning their own backup on is.
    static func resolve(
        personalGateOpen: Bool,
        remoteConfigAllowed: Bool,
        remoteConfigResolved: Bool,
        rosterStatus: String?
    ) -> TeamMemoryToggleAvailability {
        guard personalGateOpen else { return .personalGateClosed }
        // Closed until resolved (KD12): "not asked yet" is not "allowed".
        guard remoteConfigAllowed, remoteConfigResolved else { return .fleetCeilingClosed }
        switch rosterStatus {
        case "active": return .available
        case "pending": return .pendingJoin
        default: return .notAMember
        }
    }
}

// MARK: - View model

@Observable @MainActor
final class TeamMemorySectionModel {

    /// One row in the team list: the roster detail plus the local consent lever.
    struct TeamRow: Identifiable, Equatable {
        let detail: TeamRosterDetail
        let optedIn: Bool
        let availability: TeamMemoryToggleAvailability
        var id: String { detail.teamID }
    }

    private(set) var rows: [TeamRow] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The token `inviteMember` returned, shown once. Never persisted: the server
    /// stores only `sha256(token)` and cannot hand it back.
    private(set) var lastIssuedInviteToken: String?
    /// The last rotation's re-seal counters, so the row can say
    /// "re-sealing 812 of 4,010" instead of dropping the skipped documents
    /// (PR 2 review N1) — KEYED BY TEAM (PR 4 review M3).
    ///
    /// `TeamCloudVaultRewrapProgress` carries no team id of its own, so a
    /// single model-wide value rendered one team's counters under every card an
    /// admin could see: press "Rotate Key Now" on team A, and team B's card
    /// claimed 812 of 4,010 documents re-sealed in a corpus nothing had
    /// touched. The team id is stored beside the counters and
    /// `rotationProgress(forTeamID:)` is the only way to read them.
    private(set) var lastRotationProgress: (teamID: String, progress: TeamCloudVaultRewrapProgress)?
    /// The generation a rotation could not mint because another admin's wraps
    /// already occupy its envelope ids, and the team it happened on.
    ///
    /// Kept as STATE rather than folded into `errorMessage` because it is the
    /// one team failure with a real remedy this Mac can perform — burning that
    /// generation on the roster and rotating past it — and offering the remedy
    /// requires knowing WHICH generation. Cleared on the next rotation attempt
    /// and keyed by team for the same reason the progress counters are
    /// (PR 4 review M3).
    private(set) var rotationConflict: (teamID: String, conflictingVersion: Int)?
    /// The uid whose key envelopes are being written right now, so the row can
    /// say so and every "Share Team Keys" button can be held while it runs.
    /// One at a time on purpose: two concurrent passes on this Mac would race
    /// each other for the same immutable envelope ids.
    private(set) var sharingKeysForUID: String?
    /// The team that pass belongs to. Same defect class as `lastRotationProgress`
    /// (PR 4 review M3): one person can be a pending member of two teams under
    /// the same uid, and "Sharing team keys…" belongs on the row the admin
    /// actually pressed. Read through `isSharingKeys(teamID:uid:)`.
    private(set) var sharingKeysForTeamID: String?

    /// The re-seal counters for `teamID`, or nil when the last pass was another
    /// team's. Progress is a claim about a specific corpus and is never shown
    /// beside a different one.
    func rotationProgress(forTeamID teamID: String) -> TeamCloudVaultRewrapProgress? {
        guard let lastRotationProgress, lastRotationProgress.teamID == teamID else { return nil }
        return lastRotationProgress.progress
    }

    /// The generation THIS team's last rotation was blocked on, or nil.
    func rotationConflictVersion(forTeamID teamID: String) -> Int? {
        guard let rotationConflict, rotationConflict.teamID == teamID else { return nil }
        return rotationConflict.conflictingVersion
    }

    /// Whether the pass in flight is THIS team's row for THIS member.
    func isSharingKeys(teamID: String, uid: String) -> Bool {
        sharingKeysForTeamID == teamID && sharingKeysForUID == uid
    }

    private let directory: TeamMembershipDirectory
    private let roster: TeamRosterDirectoryReading
    private let admin: TeamMemoryAdministering
    private let rotator: TeamKeyRotating?
    private let joinerKeys: TeamJoinerKeyIssuing?
    private let uidProvider: @MainActor () -> String?
    private let personalGateProvider: @MainActor () -> Bool
    private let remoteConfigProvider: @MainActor () -> (allowed: Bool, resolved: Bool)
    private let optInProvider: @MainActor () -> Set<String>
    private let optInWriter: @MainActor (Set<String>) -> Void
    /// Retires this team's local sync records NOW — see `leaveTeam`. Defaults to
    /// a no-op so every seam that constructs this model without a sync domain
    /// (previews, tests of the roster half) keeps compiling; the production
    /// wiring in `PrivacyIndexingSettingsView.makeTeamMemoryModel` passes
    /// `MemoryCloudSyncDomain.invalidateTeamMemorySync(teamID:)`.
    private let invalidateTeamSync: @Sendable (String) async -> Void

    init(
        directory: TeamMembershipDirectory = UserDefaultsTeamMembershipDirectory(),
        roster: TeamRosterDirectoryReading,
        admin: TeamMemoryAdministering,
        rotator: TeamKeyRotating? = nil,
        joinerKeys: TeamJoinerKeyIssuing? = nil,
        uidProvider: @escaping @MainActor () -> String?,
        personalGateProvider: @escaping @MainActor () -> Bool,
        remoteConfigProvider: @escaping @MainActor () -> (allowed: Bool, resolved: Bool),
        optInProvider: @escaping @MainActor () -> Set<String>,
        optInWriter: @escaping @MainActor (Set<String>) -> Void,
        invalidateTeamSync: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.directory = directory
        self.roster = roster
        self.admin = admin
        self.rotator = rotator
        self.joinerKeys = joinerKeys
        self.uidProvider = uidProvider
        self.personalGateProvider = personalGateProvider
        self.remoteConfigProvider = remoteConfigProvider
        self.optInProvider = optInProvider
        self.optInWriter = optInWriter
        self.invalidateTeamSync = invalidateTeamSync
    }

    /// The signed-in account, for the one place the view needs to tell "me" from
    /// "another member" (leave vs remove).
    var signedInUID: String? { uidProvider() }

    // MARK: Load

    func refresh() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            rows = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let personalGateOpen = personalGateProvider()
        let ceiling = remoteConfigProvider()
        let optedIn = optInProvider()
        var loaded: [TeamRow] = []
        for teamID in directory.knownTeamIDs() {
            do {
                guard let detail = try await roster.rosterDetail(teamID: teamID, uid: uid) else { continue }
                loaded.append(
                    TeamRow(
                        detail: detail,
                        optedIn: optedIn.contains(teamID),
                        availability: TeamMemoryToggleAvailability.resolve(
                            personalGateOpen: personalGateOpen,
                            remoteConfigAllowed: ceiling.allowed,
                            remoteConfigResolved: ceiling.resolved,
                            rosterStatus: detail.myStatus
                        )
                    )
                )
            } catch {
                // One unreadable roster must not blank the whole section: a
                // member on two teams keeps the team they can still read.
                errorMessage = Self.message(for: error)
            }
        }
        rows = loaded.sorted { $0.detail.teamID < $1.detail.teamID }
    }

    // MARK: Consent

    /// Flip the per-team lever. Writing it is the ONLY local state change this
    /// section makes; everything else is a callable.
    func setOptIn(_ isOn: Bool, teamID: String) {
        var opted = optInProvider()
        if isOn { opted.insert(teamID) } else { opted.remove(teamID) }
        optInWriter(opted)
        rows = rows.map { row in
            row.detail.teamID == teamID
                ? TeamRow(detail: row.detail, optedIn: isOn, availability: row.availability)
                : row
        }
    }

    // MARK: Membership

    func createTeam(named name: String) async {
        await run {
            let teamID = try await self.admin.createTeam(name: name)
            self.directory.remember(teamID: teamID)
        }
    }

    /// Joining is the Semantic A moment: the confirmation the view puts in front
    /// of this call is `TeamMemoryCopy.joinSemanticA`, verbatim.
    func acceptInvite(teamID: String, token: String) async {
        await run {
            try await self.admin.acceptInvite(teamID: teamID, inviteToken: token)
            self.directory.remember(teamID: teamID)
        }
    }

    func inviteMember(teamID: String, email: String, role: String = "member") async {
        await run {
            self.lastIssuedInviteToken = try await self.admin.inviteMember(
                teamID: teamID,
                email: email,
                role: role
            )
        }
    }

    /// Leaving is the Semantic B moment: `removeTeamMember` accepts a self-leave,
    /// and the confirmation the view puts in front of it is
    /// `TeamMemoryCopy.leaveSemanticB`, verbatim.
    ///
    /// The local opt-in is cleared too. Leaving a team and leaving a consent
    /// record behind would mean re-joining silently resumed contribution.
    ///
    /// AND THE LOCAL SYNC RECORDS ARE RETIRED EAGERLY (PR 4 review §3).
    /// `TeamMemorySyncDomain.runCycle` already drops this team's pull cursor,
    /// push watermark and project-link record once it OBSERVES the team outside
    /// the opted-in set — but the cycle runs on `BehaviorSettings.refreshInterval`
    /// (600 s by default, adjustable to 15 minutes, stretched 5x by
    /// `BackgroundCadenceCoordinator` while the app is inactive, which a menu-bar
    /// app normally is). A leave and a re-join inside that window means no cycle
    /// ever saw the set without this team in it, so the very records the leave
    /// retired would still be serving the re-join: a pull cursor resumed past
    /// every fact written during the gap. Acting where the state changes is the
    /// rule `MemoryDeviceSyncInboxGuard` already follows for consent.
    ///
    /// ORDERED AFTER the opt-in is cleared, so a cycle racing this call finds
    /// the team already out of `optedInTeamIDs` and drops the same rows rather
    /// than re-establishing them. Non-throwing on purpose: the drop is an
    /// optimisation over a guarantee `runCycle` still carries, so a local delete
    /// that failed must not make a completed leave read as a failure.
    func leaveTeam(teamID: String) async {
        guard let uid = uidProvider(), !uid.isEmpty else { return }
        await run {
            try await self.admin.removeMember(teamID: teamID, targetUid: uid)
            self.setOptIn(false, teamID: teamID)
            self.directory.forget(teamID: teamID)
            await self.invalidateTeamSync(teamID)
        }
    }

    /// Removing another member is what MAKES a rotation necessary
    /// (`removeTeamMember` sets `keyRotationRequired`), which is why the
    /// destructive action is labelled "Rotate Keys and Remove".
    func removeMember(teamID: String, targetUid: String) async {
        await run { try await self.admin.removeMember(teamID: teamID, targetUid: targetUid) }
    }

    /// Rotate this team's key one generation and re-seal its facts.
    ///
    /// Only active members are wrapped for: a `pending` joiner has not been
    /// promoted (their envelopes for the retained generations are what promotion
    /// waits on) and a `removed` member is who the rotation exists to lock out.
    func rotateKey(teamID: String) async {
        guard let rotator, let row = rows.first(where: { $0.detail.teamID == teamID }) else { return }
        let activeMemberUids = row.detail.members.filter(\.isActive).map(\.uid)
        let activeKeyVersion = row.detail.activeKeyVersion
        let burnedKeyVersions = row.detail.burnedKeyVersions
        rotationConflict = nil
        await runRotation(teamID: teamID) {
            try await rotator.rotate(
                teamID: teamID,
                activeKeyVersion: activeKeyVersion,
                burnedKeyVersions: burnedKeyVersions,
                activeMemberUids: activeMemberUids
            )
        }
    }

    /// Burn the generation the last rotation collided on and rotate past it.
    ///
    /// Offered ONLY after a real `rotationConflict` on this team, because it is
    /// the only moment the conflicting generation is known and the only state in
    /// which burning one is the correct move. A rotation that merely failed —
    /// no network, a stale snapshot — is retried, not burned; spending a
    /// generation on it would be an irreversible roster write bought for
    /// nothing.
    func abandonConflictingGenerationAndRotate(teamID: String) async {
        guard let rotator,
              let conflictingVersion = rotationConflictVersion(forTeamID: teamID),
              let row = rows.first(where: { $0.detail.teamID == teamID }) else { return }
        let activeMemberUids = row.detail.members.filter(\.isActive).map(\.uid)
        let activeKeyVersion = row.detail.activeKeyVersion
        let burnedKeyVersions = row.detail.burnedKeyVersions
        await runRotation(teamID: teamID) {
            try await rotator.abandonConflictingGenerationAndRotate(
                teamID: teamID,
                conflictingVersion: conflictingVersion,
                activeKeyVersion: activeKeyVersion,
                burnedKeyVersions: burnedKeyVersions,
                activeMemberUids: activeMemberUids
            )
        }
    }

    /// The shared tail of both rotation entry points: record THIS team's
    /// counters on success, and on a `rotationConflict` record the generation so
    /// the row can offer the recovery instead of a dead "try again".
    private func runRotation(
        teamID: String,
        _ body: @escaping () async throws -> TeamCloudVaultRewrapProgress
    ) async {
        isLoading = true
        errorMessage = nil
        do {
            // Stamped with the team it describes, never bare: the counters mean
            // nothing without the corpus they counted.
            lastRotationProgress = (teamID: teamID, progress: try await body())
            rotationConflict = nil
        } catch let distribution as TeamVaultKeyDistributionError {
            if case .rotationConflict(let slot, _, _) = distribution,
               case .vault(let version)? = TeamKeySlot(rawValue: slot) {
                rotationConflict = (teamID: teamID, conflictingVersion: version)
                errorMessage = TeamMemoryCopy.rotationConflictNotice
            } else {
                errorMessage = Self.message(for: distribution)
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
        await refresh()
    }

    // MARK: Sharing a joiner's keys

    /// Whether THIS Mac can issue `member`'s key envelopes.
    ///
    /// Three conditions, every one of them necessary. The reader must be an
    /// ACTIVE ADMIN, because `firestore.rules` permits a wrap addressed to
    /// another member only for one and `promoteTeamMember` refuses otherwise —
    /// so a non-admin sees the pending row exactly as it is, read-only, with no
    /// button that would only ever be denied. The target must still be
    /// `pending`, because promotion is the one transition this action makes.
    /// And this build must have been handed the distributor seam at all.
    func canShareTeamKeys(row: TeamRow, member: TeamRosterDetail.Member) -> Bool {
        joinerKeys != nil && row.detail.isAdmin && member.isPending
    }

    /// Issue every retained team key plus the slug key to a pending member's
    /// pinned devices, then promote them.
    ///
    /// The retained list comes from the ROSTER, never from this Mac's key ring:
    /// the roster is the sole authority for which generations a joiner has to be
    /// able to open, and wrapping only what this device happens to hold is how a
    /// joiner ends up unable to read the oldest half of the team's history.
    func shareTeamKeys(teamID: String, joinerUid: String) async {
        guard let joinerKeys,
              sharingKeysForUID == nil,
              let row = rows.first(where: { $0.detail.teamID == teamID }),
              let member = row.detail.members.first(where: { $0.uid == joinerUid }),
              canShareTeamKeys(row: row, member: member)
        else { return }
        let retainedKeyVersions = row.detail.retainedKeyVersions
        sharingKeysForUID = joinerUid
        sharingKeysForTeamID = teamID
        errorMessage = nil
        isLoading = true
        do {
            try await joinerKeys.issueKeys(
                teamID: teamID,
                joinerUid: joinerUid,
                retainedKeyVersions: retainedKeyVersions
            )
        } catch {
            // Typed, and never the raw text: a callable message can carry the
            // member's email, and two of the roster's refusals share a status
            // code and differ only in wording.
            errorMessage = TeamJoinerKeyIssueFailure.classify(error).message(member: joinerUid)
        }
        sharingKeysForUID = nil
        sharingKeysForTeamID = nil
        isLoading = false
        // ALWAYS, success or failure. On success the row this admin just acted
        // on is `active` and no longer offers the button; on a C-3 refusal the
        // member list is exactly what tells them why.
        await refresh()
    }

    // MARK: Rotation status

    /// What the row says about the team's current key generation.
    ///
    /// BOTH HALVES, ALWAYS. `rotateTeamKey` advances `activeKeyVersion` and
    /// clears `keyRotationRequired` BEFORE a single fact is re-sealed — it must,
    /// because the rules pin fact writes to the roster's active generation — so
    /// "rotated" and "re-sealed" are different facts and the roster alone cannot
    /// tell them apart. The completion field is what distinguishes them.
    static func rotationStatusLines(
        for detail: TeamRosterDetail,
        progress: TeamCloudVaultRewrapProgress? = nil
    ) -> [String] {
        var lines = [TeamMemoryCopy.rotationStatus(activeKeyVersion: detail.activeKeyVersion)]
        if detail.keyRotationRequired {
            lines.append(TeamMemoryCopy.rotationRequiredNotice)
        }
        lines.append(
            detail.isRewrapComplete
                ? TeamMemoryCopy.rewrapComplete(keyVersion: detail.activeKeyVersion)
                : TeamMemoryCopy.rewrapIncomplete(keyVersion: detail.activeKeyVersion)
        )
        // BOTH NUMBERS, NEVER JUST THE RE-SEALED ONE (PR 2 review N1). A pass
        // that skipped documents is not a finished rotation, and "812 re-sealed"
        // on its own reads exactly like one.
        if let progress {
            lines.append(
                TeamMemoryCopy.rewrapProgress(
                    resealed: progress.rewrappedDocuments,
                    scanned: progress.scannedDocuments
                )
            )
        }
        return lines
    }

    // MARK: Plumbing

    private func run(_ body: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        do {
            try await body()
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
        await refresh()
    }

    /// Never the raw error: a callable's message can carry a uid or an email the
    /// section has no business rendering.
    static func message(for error: Error) -> String {
        "That team action did not complete. Check your connection and try again."
    }
}
