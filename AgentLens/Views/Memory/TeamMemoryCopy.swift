import Foundation

/// Canonical user-facing copy for Team Memory spaces (memory program D16 / P22).
///
/// ONE PLACE, BECAUSE THE COPY IS THE PROMISE. Every string a member reads about
/// a team space lives here and is pinned by `TeamMemoryCopyGateTests`, so the two
/// operational semantics that cryptography cannot change can never drift out of
/// the shipped UI:
///
///   * **Semantic A — joining reads history.** A joiner is issued an envelope for
///     every RETAINED team key version before the roster promotes them to
///     `active` (`promoteTeamMember` refuses otherwise), so the moment they can
///     sync at all they can open everything the team has ever sealed. There is no
///     "from now on" mode, and offering one would be a lie about a shared
///     symmetric key.
///   * **Semantic B — leaving protects the future only.** Removal cuts the ex
///     member off at the roster on the very next read or write, and the rotation
///     that follows makes facts sealed under `v(N+1)` undecryptable to them.
///     Neither retracts a single bit their devices already hold.
///
/// HONESTY. This lane is **blind** — the repo-sanctioned word — and never the
/// stronger claim `scripts/ci/verify-signal-honesty-copy.sh` bans, which a shared
/// symmetric key every member holds could not support anyway.
/// The server holds ciphertext, opaque keyed document ids, opaque source
/// hashes, a coarse `kind`, the author's uid and timestamps — and it owns the
/// membership graph outright, because a client cannot be trusted to assert who is
/// on a team. It never holds a fact body, a citation or any team key.
/// `scripts/ci/verify-signal-honesty-copy.sh` bans the over-claims across the
/// whole app; `test_no_team_copy_string_contains_a_banned_over_claim` mirrors that
/// list in-process so a bad string fails a unit test before it ever reaches CI.
///
/// NOT A CONFIDENTIALITY BOUNDARY BETWEEN MEMBERS. Every active member holds the
/// team vault key, so every active member can read every team fact. The per-team
/// switch is a contribution and display control. `settingsFootnote` says that in
/// the shipped UI rather than only in the threat model.
enum TeamMemoryCopy {

    // MARK: Section chrome

    static let sectionTitle = "Team Memory"

    static let sectionSubtitle =
        "Share approved project memories with a team. Blind: the server holds sealed facts, opaque ids and wrapped keys — never your memory text or any team key."

    static let joinHeader = "Join Team Memory Space"

    // MARK: The two semantics (kept VERBATIM from the held attempt, design §6)

    static let joinSemanticA =
        "Joining a team grants read access to all team memories sealed under the team's active keys, including memories contributed by team members before you joined."

    static let leaveSemanticB =
        "Leaving or being removed from a team revokes your server access and rotates the team encryption key for future memories. However, it cannot erase memories or keys that have already been downloaded to your devices."

    /// The one string that had to be rewritten. The held attempt claimed a
    /// property the honesty gate bans by name — and it would have been false
    /// even if it were permitted: every active member holds the same symmetric
    /// key, so there is nothing the server is being kept ignorant of that the
    /// members are not all equally able to read.
    static let settingsFootnote =
        "Team memory is blind, not private between members: the server holds sealed facts, opaque ids and "
        + "wrapped per-device keys, but every active member holds the team key and can read every team fact. "
        + "Joining a team grants access to the team's existing history; leaving protects future memories "
        + "only — rotation cannot retract what your devices already hold."

    // MARK: Join / leave confirmation

    static let joinAlertTitle = "Join This Team Space?"
    static let joinConfirmAction = "Join Team"

    static let leaveAlertTitle = "Leave This Team Space?"
    static let leaveConfirmAction = "Leave Team"

    static let alertTitle = "Remove Member from Team?"
    static let alertDestructiveAction = "Rotate Keys and Remove"

    /// Shown under `alertTitle`: removing a member is what makes a rotation
    /// necessary, and the rotation is what an admin then has to run.
    static let removeMemberDetail =
        "Removing a member cuts their access at the next read or write and marks this team for a key rotation. Rotation protects memories sealed after it; it cannot retract memories the removed member already downloaded."

    static let cancelAction = "Cancel"

    // MARK: Admin — issuing a joiner's key envelopes (design §3(b)2)

    static let shareKeysAction = "Share Team Keys"

    static let shareKeysInProgress = "Sharing team keys…"

    /// Shown to an admin who has a pending member. Promotion is the moment
    /// Semantic A becomes true for the joiner, and the admin is the one taking
    /// it, so the button is not offered without saying what it grants: the
    /// envelopes cover every RETAINED generation, so the instant this succeeds
    /// the joiner can open everything the team has ever sealed.
    static let shareKeysDetail =
        "Sharing the team keys issues this member's devices an encrypted copy of every team key and then makes them "
        + "active. From that moment they can read every memory this team has sealed, including memories contributed "
        + "before they joined."

    /// Both `rotationConflict` (another admin's wrap already occupies an
    /// envelope id this pass needs) and `rosterStateMovedInFlight` (the roster's
    /// key state moved between the coverage check and the commit) mean one thing
    /// to the admin reading it, and the same thing to do about it. Naming the
    /// other admin would be a claim this client cannot make — it sees an
    /// envelope or an `aborted`, not a person.
    static let shareKeysConflictNotice =
        "Another admin is changing this team right now. Nothing was shared. Try again in a moment."

    /// The coverage failure, named rather than generic: no envelope can be
    /// written because the joiner has published no trusted device for one to be
    /// addressed to. The fix is theirs, not the admin's, so the copy says whose.
    static func shareKeysNoTrustedDevice(member: String) -> String {
        "\(member) has not published a trusted device yet, so there is nothing to send the team keys to. "
        + "Ask them to open BurnBar and sign in on the Mac they want to use this team space from, then share again."
    }

    /// The C-3 refusal: the roster re-reads `status == "pending"` at write time,
    /// so a member removed or promoted while this admin was wrapping is a
    /// `failed-precondition`, not a failure of the wrap.
    static let shareKeysNoLongerPendingNotice =
        "That member is no longer waiting to join this team. The member list now shows their current status."

    static let shareKeysFailedNotice =
        "Sharing the team keys did not complete. No member was made active. Check your connection and try again."

    // MARK: States

    static let pendingJoinNotice = "Waiting for a team admin to share the team keys."

    static let pendingJoinDetail =
        "You have accepted the invite. A team admin's Mac issues your device an encrypted copy of every team key it needs before the roster makes you active — until then this team syncs nothing."

    /// Named levers, all of them, because the row is disabled by
    /// `MemoryDeviceSyncScope.current(...).isOpen` — the personal memory levers
    /// AND the account ones (PR 4 review L4). A member with cloud backup on but
    /// account cloud sync off was previously told to turn on two switches that
    /// were already on.
    static let personalGateClosedNotice =
        "Turn on cloud sync for your account, then \"Back up approved memories\" and \"Sync memories to my other devices\". Team memory is a subset of your own memory sync, so it stays off while any of those are off."

    static let remoteConfigClosedNotice =
        "Team memory is temporarily disabled by your admin. Your own memories are unaffected."

    static let rotationRequiredNotice =
        "This team needs a key rotation. A team admin re-seals the team's memories under a new key."

    /// The `rotationConflict` refusal, in an admin's terms.
    ///
    /// HONEST ABOUT ALL THREE FACTS, because each one changes what to do:
    /// nothing was written (the pass pre-scans every envelope id it would have
    /// to claim before writing any), the other admin's pass may still be
    /// running, and this generation can never be retried — envelope documents
    /// are create-only, so the ids are occupied by wraps of a key this Mac does
    /// not hold. It does NOT say "try again": trying again is the one thing
    /// that cannot work.
    static let rotationConflictNotice =
        "Another admin's Mac is already distributing this key generation, and it wraps a key this Mac does not hold. "
        + "Nothing was written and nothing was shared. If their rotation is still running, wait for it to finish."

    /// The recovery button. Named for what it DOES to the roster, not for how it
    /// feels: it spends a key generation permanently.
    static let abandonGenerationAction = "Skip That Generation"

    /// What pressing it costs, before it is pressed.
    static func abandonGenerationDetail(version: Int) -> String {
        "If that rotation was abandoned, the team can step over it: the server records generation \(version) as "
        + "unusable, and this Mac rotates the team to the generation after it. Generation \(version) is then never "
        + "used again. Pressing this twice is safe — it records the same generation and nothing else."
    }

    static let emptyTeamsNotice = "You are not in a team memory space yet."

    // MARK: Actions

    static let createTeamAction = "Create Team"
    static let joinWithTokenAction = "Join with Invite"
    static let inviteMemberAction = "Invite by Email"
    static let rotateNowAction = "Rotate Key Now"
    static let removeMemberAction = "Remove"
    static let syncToggleTitle = "Sync memories with this team"

    static let syncToggleSubtitle =
        "Contribute approved memories for team-linked projects, and read the team's back. Off for every team by default."

    static let inviteTokenFieldPrompt = "Invite token"
    static let inviteEmailFieldPrompt = "Member email"
    static let teamNameFieldPrompt = "Team name"

    /// The member list is a READ of a server-owned collection; nothing in this
    /// section writes to it, and the copy says so rather than implying a local
    /// edit could stick.
    static let memberListCaption = "Members are recorded by the server. This list is read-only."

    // MARK: Rotation status

    static func rotationStatus(activeKeyVersion: Int) -> String {
        "Active key: generation \(activeKeyVersion)."
    }

    /// The completion note the rotation records on the ROSTER (PR 2 review N1,
    /// promoted from a local `UserDefaults` note in PR 4), so every member sees
    /// it and not only the admin who happened to run the pass.
    static func rewrapComplete(keyVersion: Int) -> String {
        "Every team memory has been re-sealed under generation \(keyVersion)."
    }

    static func rewrapIncomplete(keyVersion: Int) -> String {
        "Team memories are still being re-sealed under generation \(keyVersion)."
    }

    /// Progress must name BOTH numbers (PR 2 review N1): a pass that skipped
    /// documents is not a completed rotation, and reporting only the re-sealed
    /// count would read as one.
    static func rewrapProgress(resealed: Int, scanned: Int) -> String {
        "Re-sealing \(resealed) of \(scanned)."
    }

    // MARK: Memory provenance badge

    static let teamFactBadgeLabel = "Team Fact"

    /// `Team Fact · contributed by <member>` on a memory row whose engine history
    /// carries a `teamID`. The member string is the author's account id as the
    /// engine recorded it — this lane never learns a display name, and inventing
    /// one would be a claim about a directory the client cannot read.
    static func teamFactAttribution(member: String) -> String {
        "\(teamFactBadgeLabel) · contributed by \(member)"
    }

    /// A team fact whose `authorUID` did not survive into the parked payload
    /// (PR 4 review L5).
    ///
    /// The fallback used to be the TEAM id, which rendered "contributed by
    /// team_abcdef0123456789" — a team is not a contributor, and a copy-honesty
    /// lane may not attribute a fact to something that never wrote one. The row
    /// still says it is a team fact, because that part is known.
    static let teamFactUnknownContributor = "\(teamFactBadgeLabel) · contributor unknown"

    /// A team fact whose team this Mac no longer lists (PR 4 review N5).
    ///
    /// The lift is scoped to the member and the `team:` doc-id prefix, never to
    /// the current roster, so a fact parked from a team the member has since
    /// LEFT still badges — correctly, because the fact did come from there. What
    /// was wrong was saying nothing about it: `Team Fact · contributed by <uid>`
    /// reads as a live membership, and the uid is only interpretable against a
    /// roster this member can no longer read.
    ///
    /// THE CONTRIBUTOR LINE IS DROPPED RATHER THAN MARKED, and the team is named
    /// by neither id nor name. The only local record of "which teams am I in" is
    /// `UserDefaultsTeamMembershipDirectory` — a navigation cache of team IDS
    /// with no names in it at all — so a "(former team) <name>" marker would
    /// have to invent the name or print an opaque `team_…` token at a member.
    /// The copy therefore says exactly what this Mac can support: the fact came
    /// from a team, and this Mac's own list no longer has that team on it. It
    /// deliberately does NOT say "you left" — the cache is not authority
    /// (`refresh()` re-reads the roster every time), and a cleared or migrated
    /// cache must not be rendered as a membership claim.
    static let teamFactFormerTeam = "\(teamFactBadgeLabel) · from a team this Mac no longer lists"

    // MARK: The gate's own inventory

    /// Every shipped string in this enum, including one rendering of each
    /// formatter.
    ///
    /// ADD EVERY NEW STRING HERE. `test_no_team_copy_string_contains_a_banned_over_claim`
    /// walks this list with an in-process mirror of the CI honesty gate's banned
    /// phrases, so a bad string fails a unit test in seconds instead of a CI job
    /// in minutes. The list is a CONVENIENCE, not the enforcement: the real gate
    /// is `scripts/ci/verify-signal-honesty-copy.sh`, which scans this file's
    /// text — so a string omitted from the list is still caught, just later.
    ///
    /// COMPLETENESS IS ENFORCED (PR 4 review L9). It used to be hand-maintained
    /// with nothing checking it, so a new string could silently escape the fast
    /// mirror. `scripts/ci/verify-team-memory-copy-inventory.sh` now fails when a
    /// `static let` or `static func` declared above is missing from this list;
    /// it runs in the `signal-honesty-copy` job beside the phrase gate. A string
    /// that genuinely must not be listed is opted out with a
    /// `// copy-inventory: exempt` comment on the line above its declaration,
    /// and the exemption is then visible in review.
    static let allCopy: [String] = [
        sectionTitle,
        sectionSubtitle,
        joinHeader,
        joinSemanticA,
        leaveSemanticB,
        settingsFootnote,
        joinAlertTitle,
        joinConfirmAction,
        leaveAlertTitle,
        leaveConfirmAction,
        alertTitle,
        alertDestructiveAction,
        removeMemberDetail,
        cancelAction,
        shareKeysAction,
        shareKeysInProgress,
        shareKeysDetail,
        shareKeysConflictNotice,
        shareKeysNoLongerPendingNotice,
        shareKeysFailedNotice,
        pendingJoinNotice,
        pendingJoinDetail,
        personalGateClosedNotice,
        remoteConfigClosedNotice,
        rotationRequiredNotice,
        rotationConflictNotice,
        abandonGenerationAction,
        emptyTeamsNotice,
        createTeamAction,
        joinWithTokenAction,
        inviteMemberAction,
        rotateNowAction,
        removeMemberAction,
        syncToggleTitle,
        syncToggleSubtitle,
        inviteTokenFieldPrompt,
        inviteEmailFieldPrompt,
        teamNameFieldPrompt,
        memberListCaption,
        teamFactBadgeLabel,
        rotationStatus(activeKeyVersion: 2),
        rewrapComplete(keyVersion: 2),
        rewrapIncomplete(keyVersion: 2),
        rewrapProgress(resealed: 812, scanned: 4010),
        teamFactUnknownContributor,
        teamFactFormerTeam,
        abandonGenerationDetail(version: 4),
        shareKeysNoTrustedDevice(member: "member-uid"),
        teamFactAttribution(member: "member-uid")
    ]
}
