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

    /// Reads `<projectRoot>/.openburnbar/project.json`, bounded to `maxBytes`.
    /// An absent, unreadable or oversized file is an empty link, for the same
    /// reason a malformed one is.
    static func read(projectRoot: URL) -> TeamProjectLink {
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
