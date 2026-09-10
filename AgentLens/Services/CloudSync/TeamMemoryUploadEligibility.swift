import Foundation
import OpenBurnBarKernel

// MARK: - What may be contributed to a team (memory program D16 / P22, PR 3)
//
// Sharing a memory with a team is a WIDER egress than sealing it into the
// member's own vault: the personal lane's readers are the member's own Macs;
// this lane's readers are every active member of the team, now and in the
// future, including people who join later (Semantic A). So eligibility is
// decided by its own function rather than inherited from the personal one, and
// it is strictly narrower.

/// The checked-in team link for one repository.
///
/// WHY THIS FILE EXISTS AT ALL. A team document id derives from the engine's
/// convergence identity `(project_id, scope, body_hash)`, and the engine's own
/// `project_id` is `"proj_" + sha256("v2:origin:<remote.origin.url>|<root
/// commit>")[:32]` (`project_code_memory.py`). A member who cloned over SSH
/// (`git@github.com:org/repo.git`) and one who cloned over HTTPS
/// (`https://github.com/org/repo.git`) therefore derive DIFFERENT project ids
/// for the same repository — and an adopted project id outranks the fingerprint
/// entirely. Every team document id would inherit that split, and the failure
/// would be silent and asymmetric: uploads succeed, dedup never fires, and half
/// the team sees a team space that looks half empty.
///
/// So the doc-id pre-image uses an explicit, checked-in id instead. It lives in
/// the repository the team shares, is read-only to this app, and is the same
/// bytes on every clone by construction:
///
/// ```json
/// { "teams": { "team_0123456789abcdef": { "teamProjectId": "burnbar-core" } } }
/// ```
///
/// A project with no entry for a team contributes nothing to that team. That is
/// the deliberate default: a member cannot accidentally publish a repository the
/// team never agreed to share, and no UI can opt one in — only a commit can.
struct TeamProjectLink: Equatable, Sendable {
    /// The path, relative to a repository root, where the link file lives.
    static let relativePath = ".openburnbar/project.json"

    /// The most of that file this reader will ever hold in memory.
    ///
    /// The schema above is a few hundred bytes at any plausible team count, and
    /// the engine's analogous repository-dotfile reader caps at
    /// `PROJECT_DOTFILE_MAX_BYTES = 256` for exactly this class of input:
    /// reading more than the schema can justify is reading an attacker's
    /// payload, not a link file. Anything larger is refused whole — an empty
    /// link, i.e. this repository contributes nothing — rather than truncated,
    /// because a truncated JSON document is a parse failure with extra steps.
    static let maxBytes = 2_048

    /// `teamId` -> `teamProjectId`. Every value here is already known to be
    /// inside `TeamMemorySyncService.teamProjectIDPattern`; `decode` drops the
    /// ones that are not.
    let teamProjectIDsByTeamID: [String: String]

    /// How many entries the file named that this reader refused. Counted rather
    /// than thrown, and surfaced so a repository whose link file is wrong is a
    /// log line rather than a silence.
    let droppedEntries: Int

    init(teamProjectIDsByTeamID: [String: String], droppedEntries: Int = 0) {
        self.teamProjectIDsByTeamID = teamProjectIDsByTeamID
        self.droppedEntries = droppedEntries
    }

    /// The id this repository publishes to `teamID`, or nil when it publishes
    /// nothing to it.
    func teamProjectID(forTeam teamID: String) -> String? {
        teamProjectIDsByTeamID[teamID]
    }

    /// Decodes the minimal schema above. Anything else — a missing `teams`
    /// object, a non-string id, trailing junk — yields an EMPTY link rather than
    /// a throw: a malformed file must leave the repository contributing nothing,
    /// never fail the whole sync cycle for the teams that are configured
    /// correctly.
    ///
    /// An entry whose `teamProjectId` is outside
    /// `TeamMemorySyncService.teamProjectIDPattern` is DROPPED AND COUNTED, by
    /// the same rule and for the same reason: this string is member-authored
    /// text from a shared repository that ends up in plaintext engine state on
    /// every teammate's Mac, so an unbounded one is a prompt-injection channel.
    /// Dropping the entry (rather than refusing the file) keeps a second team's
    /// correct entry working, and the repository simply publishes nothing to the
    /// team whose entry is wrong — the same fail-closed default as naming no
    /// team at all.
    static func decode(from data: Data) -> TeamProjectLink {
        struct Wire: Decodable {
            struct Entry: Decodable { let teamProjectId: String? }
            let teams: [String: Entry]?
        }
        let decoder = JSONDecoder()
        do {
            let wire = try decoder.decode(Wire.self, from: data)
            var links: [String: String] = [:]
            var dropped = 0
            for (teamID, entry) in wire.teams ?? [:] {
                guard let id = entry.teamProjectId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else {
                    dropped += 1
                    continue
                }
                guard TeamMemorySyncService.isWellFormedTeamProjectID(id) else {
                    dropped += 1
                    continue
                }
                links[teamID] = id
            }
            return TeamProjectLink(teamProjectIDsByTeamID: links, droppedEntries: dropped)
        } catch {
            return TeamProjectLink(teamProjectIDsByTeamID: [:])
        }
    }

    /// THE ELIGIBILITY READ. An entry counts only when the working tree and
    /// `HEAD` name the same `teamProjectId` for the team.
    ///
    /// **D16 Cursor ruling (HIGH).** The doc comment above calls this file "a
    /// checked-in, human decision"; before this, the code read the WORKING TREE,
    /// which made it a decision anything able to write a file could take.
    /// Anything that can write in a private checkout — an agent, a
    /// prompt-injected tool call — could opt that repository into a team this
    /// Mac already syncs, and its approved memories then became eligible to
    /// upload under the teammates' agreed `teamProjectId`, with no human
    /// confirmation and no commit anywhere. This lane's readers are every member
    /// of the team, now and in future (Semantic A), so the write that opens it
    /// has to be one a human made and a repository records.
    ///
    /// The intersection is taken PER ENTRY, and both directions fail closed:
    ///
    /// * committed and unmodified -> a link;
    /// * working tree only (never committed, or committed and then re-pointed)
    ///   -> NOT a link: nobody agreed to it;
    /// * `HEAD` only (deleted or edited out locally) -> NOT a link either, which
    ///   keeps the property the serving fence was built for — taking the link
    ///   away stops the lane on the very next cycle, without waiting for a
    ///   commit.
    ///
    /// Per entry, not per file: failing a dirty file closed as a whole would let
    /// an in-progress edit adding team B silently stop team A, whose entry was
    /// committed and agreed weeks ago. The attack is an entry `HEAD` does not
    /// carry, and per-entry closes exactly that.
    ///
    /// A checkout with no git work tree, an unborn branch, or no committed link
    /// file publishes nothing. That is the fail-closed answer and the only
    /// honest one: a directory with nothing checked in has checked in no
    /// decision.
    ///
    /// `memory_engine/_namespaces.py::_session_team_links` is the same rule on
    /// the engine side, and the two are meant to agree entry for entry.
    static func read(projectRoot: URL) -> TeamProjectLink {
        let working = readWorkingTree(projectRoot: projectRoot)
        guard !working.teamProjectIDsByTeamID.isEmpty else {
            // Nothing in the working tree can intersect with anything, so the
            // git read is skipped: the common case (no link file) stays one
            // bounded file read and no subprocess.
            return working
        }
        let committed = readCommitted(projectRoot: projectRoot)
        let effective = working.teamProjectIDsByTeamID.filter { team, id in
            committed.teamProjectIDsByTeamID[team] == id
        }
        if effective.count < working.teamProjectIDsByTeamID.count {
            // Neither an error nor a silence: a member who wrote a link and did
            // not commit it has a repository that publishes nothing, and this is
            // the operator-visible half of `burnbar_memory_doctor`'s
            // `linkWrittenButNotCommitted`. Ids are not logged.
            AppLogger.sync.error(
                "team_memory_project_link_not_committed",
                metadata: ["count": String(working.teamProjectIDsByTeamID.count - effective.count)]
            )
        }
        return TeamProjectLink(teamProjectIDsByTeamID: effective, droppedEntries: working.droppedEntries)
    }

    /// The working-tree half: `<projectRoot>/.openburnbar/project.json`, bounded
    /// to `maxBytes`. An absent, unreadable or oversized file is an empty link,
    /// for the same reason a malformed one is.
    ///
    /// NOT an eligibility answer on its own — `read` is. This exists so the
    /// intersection has two named halves that can each be tested, and so a
    /// future surface that wants to tell a human "you wrote this and did not
    /// commit it" has an honest way to ask.
    static func readWorkingTree(projectRoot: URL) -> TeamProjectLink {
        let url = projectRoot.appendingPathComponent(relativePath)
        let link: TeamProjectLink
        do {
            guard let data = try readBounded(url) else {
                AppLogger.sync.error("team_memory_project_link_too_large", metadata: ["limit": String(maxBytes)])
                return TeamProjectLink(teamProjectIDsByTeamID: [:])
            }
            link = decode(from: data)
        } catch {
            return TeamProjectLink(teamProjectIDsByTeamID: [:])
        }
        if link.droppedEntries > 0 {
            // The file's own path is not logged: it is a member's local
            // repository path. The count is what an operator needs.
            AppLogger.sync.error(
                "team_memory_project_link_entries_dropped",
                metadata: ["count": String(link.droppedEntries)]
            )
        }
        return link
    }

    /// The committed half: the link file's bytes as they exist at `HEAD`.
    ///
    /// Every way there can fail to be a committed blob at that path collapses to
    /// the same empty link — not a git work tree, unborn branch, path untracked,
    /// `HEAD` naming a tree or submodule there, git missing, git hung — because
    /// a caller that could tell those apart is a caller that could be talked
    /// into treating "no repository" as "committed".
    static func readCommitted(projectRoot: URL) -> TeamProjectLink {
        guard let data = committedBlob(projectRoot: projectRoot, path: relativePath) else {
            return TeamProjectLink(teamProjectIDsByTeamID: [:])
        }
        return decode(from: data)
    }

    /// `git show HEAD:<path>`, bounded to `maxBytes`, or nil.
    ///
    /// Bounded by reading the pipe rather than by checking a size afterwards: a
    /// `readDataToEndOfFile` on an attacker-sized blob would already have paid
    /// the cost, which is the same argument `readBounded` makes about the file.
    /// The environment is stripped of `GIT_*` and every prompt is disarmed, on
    /// the pattern `ReceiptAccomplishmentSynthesizer.runGitCommand` established:
    /// this runs against a member's own repository, and a repository must not be
    /// able to make it ask a question or reach the network.
    private static func committedBlob(projectRoot: URL, path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", projectRoot.path,
            "--no-optional-locks",
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "show", "HEAD:\(path)"
        ]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let handle = pipe.fileHandleForReading
        // try?-ok(a failed pipe read is an empty blob, which the returnStatus/size guard below turns into "no committed link" — the fail-closed answer every other failure mode here already produces)
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        try? handle.close() // try?-ok(read-only teardown of a bounded pipe read)
        guard process.terminationStatus == 0, data.count <= maxBytes else { return nil }
        return data
    }

    /// Reads at most `maxBytes` from `url`, or nil when the file is larger.
    ///
    /// Reads `maxBytes + 1` and checks the count, so "exactly at the limit" is
    /// accepted and "one byte over" is refused without ever holding the whole
    /// file — a `Data(contentsOf:)` on an attacker-sized file would already have
    /// paid the cost by the time any check could run.
    private static func readBounded(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() } // try?-ok(read-only teardown of a bounded local read)
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        return data.count > maxBytes ? nil : data
    }
}

/// Why a local memory is not eligible for a team, when it is not.
///
/// A log dimension and a test assertion, never a UI string: an ineligible row is
/// simply not uploaded, and the member is told nothing about individual rows.
enum TeamMemoryUploadRefusal: String, Equatable, Sendable {
    /// The member has not opted this team in. The default for every team.
    case teamNotOptedIn = "team_not_opted_in"
    /// Not `reviewStatus == .approved`. Quarantined and rejected rows never
    /// leave the device on any lane.
    case notApproved = "not_approved"
    /// Not an engine-mirrored row. A chat memory has no `bodyHash` and no
    /// engine project, so it has no convergence identity and can never key a
    /// team document — exactly the reasoning `MemoryCloudPullService` applies to
    /// `projectIdentityMissing` on the personal lane.
    case notEngineMirrored = "not_engine_mirrored"
    /// The row carries no `bodyHash` / `engineScope` even though it claims to be
    /// engine-mirrored, so there is no identity to derive an id from.
    case missingConvergenceIdentity = "missing_convergence_identity"
    /// The row's project publishes nothing to this team in
    /// `.openburnbar/project.json`.
    case projectNotLinkedToTeam = "project_not_linked_to_team"
    /// The shared secret/PII gate found something in the body.
    case sensitivityFlagged = "sensitivity_flagged"
    /// The row is retired (`validTo != nil`). Retirement travels as a forget
    /// receipt, never as a fact.
    case retired = "retired"
}

/// The eligibility decision, as one pure function.
///
/// Every lever is an argument, so the whole rule is testable without a database,
/// a Keychain, an account or a filesystem — and so a future lever (the org
/// ceiling, see `TeamMemorySyncGate`) is added in one visible place.
enum TeamMemoryUploadEligibility {
    /// - Parameter bodyForSensitivityScan: the plaintext this upload would
    ///   publish to the team. It is re-gated HERE, at the team boundary, rather
    ///   than trusted to have been gated at write time: the write-time gate
    ///   decided whether the member's own vault may hold it, which is a
    ///   different question from whether a team may. `MemorySecretPIIGate` is
    ///   the shared, fail-closed spine both answers use, and it rejects with a
    ///   synthetic finding when its corpus is unavailable — so an install with a
    ///   broken corpus contributes nothing rather than contributing blind.
    static func refusal(
        teamOptIn: Bool,
        reviewStatus: MemoryReviewStatus,
        sourceKind: MemorySourceKind,
        validTo: Date?,
        bodyHash: String?,
        engineScope: String?,
        teamProjectID: String?,
        bodyForSensitivityScan: String
    ) -> TeamMemoryUploadRefusal? {
        guard teamOptIn else { return .teamNotOptedIn }
        guard reviewStatus == .approved else { return .notApproved }
        guard sourceKind == .agent else { return .notEngineMirrored }
        guard validTo == nil else { return .retired }
        guard let bodyHash, !bodyHash.isEmpty,
              let engineScope, !engineScope.isEmpty else {
            return .missingConvergenceIdentity
        }
        guard let teamProjectID, !teamProjectID.isEmpty else { return .projectNotLinkedToTeam }
        guard case .allow = MemorySecretPIIGate.evaluate(bodyForSensitivityScan, policy: .reject) else {
            return .sensitivityFlagged
        }
        return nil
    }

    /// Sugar for the call sites that only need the verdict.
    static func qualifies(
        teamOptIn: Bool,
        reviewStatus: MemoryReviewStatus,
        sourceKind: MemorySourceKind,
        validTo: Date?,
        bodyHash: String?,
        engineScope: String?,
        teamProjectID: String?,
        bodyForSensitivityScan: String
    ) -> Bool {
        refusal(
            teamOptIn: teamOptIn,
            reviewStatus: reviewStatus,
            sourceKind: sourceKind,
            validTo: validTo,
            bodyHash: bodyHash,
            engineScope: engineScope,
            teamProjectID: teamProjectID,
            bodyForSensitivityScan: bodyForSensitivityScan
        ) == nil
    }
}
