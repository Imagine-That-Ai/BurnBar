import Foundation
import Observation

/// View-model backing `MemoryTimelineView`.
///
/// B8: presents one memory's history — the ordered events recorded against it,
/// its lineage, and when it was last touched.
///
/// **Which history this is.** The engine (`memory_engine/_read.py`) serves a
/// timeline of REVISION BODIES out of its own store, `openburnbar-memory.sqlite`
/// — plain SQLite with per-field AES-GCM whose key never leaves the engine. No
/// Swift process reads that store and none should. What this model renders comes
/// from `memory_audit`, the app's own hash-chained ledger of what HAPPENED to a
/// memory. Every result therefore carries `source`, and a result whose
/// `revisionBodiesRetained` is false says out loud that revision contents were
/// never retained — otherwise empty `before`/`after` would read as "nothing
/// changed" instead of "not recorded".
///
/// The member names are the ENGINE'S, so a future daemon-forwarded engine
/// timeline can drive this same model without a rename: `ts` (not `timestamp`),
/// `code` (not `refusalCode`), `meta` (a dict, not a pre-rendered summary), and
/// a `status` with three values — `ok`, `not_found`, `refused`. `not_found` is
/// deliberately distinct from an `ok` read with no revisions: the first means
/// "nothing here knows that id", the second means "known, nothing has happened
/// to it yet".
///
/// A refusal must carry **no** revisions, lineage or last-helped: a foreign
/// memory id leaks nothing, not even its shape. The engine enforces that; this
/// model enforces it again locally, so a server that refused-but-still-answered
/// still renders nothing.
@Observable @MainActor
final class MemoryTimelineModel {

    /// One event in the memory's history.
    struct RevisionItem: Identifiable, Equatable {
        let seq: Int
        let event: String
        let actor: String
        let ts: String
        let before: String?
        let after: String?
        let writerDevice: String?
        let meta: [String: String]

        var id: Int { seq }

        init(
            seq: Int,
            event: String,
            actor: String,
            ts: String,
            before: String? = nil,
            after: String? = nil,
            writerDevice: String? = nil,
            meta: [String: String] = [:]
        ) {
            self.seq = seq
            self.event = event
            self.actor = actor
            self.ts = ts
            self.before = before
            self.after = after
            self.writerDevice = writerDevice
            self.meta = meta
        }

        /// Title case for the events both histories name; anything either side
        /// adds later renders readably rather than disappearing.
        var displayEvent: String {
            switch event {
            case "created", "memory.add": "Created"
            case "updated", "memory.update": "Updated"
            case "retired", "memory.delete": "Retired"
            case "reactivated": "Reactivated"
            case "synced": "Synced"
            case "memory.approve": "Approved"
            case "memory.reject": "Rejected"
            case "memory.merge": "Merged"
            case "memory.supersede": "Superseded"
            default: event.replacingOccurrences(of: "memory.", with: "").replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        /// The one-line rendering of `meta`, stable across runs so the row does
        /// not reshuffle between loads.
        var metaSummary: String? {
            guard meta.isEmpty == false else { return nil }
            return meta.keys.sorted().map { "\($0): \(meta[$0] ?? "")" }.joined(separator: " · ")
        }
    }

    /// One timeline read, as the loader returns it.
    struct TimelineResult: Equatable {
        let status: String
        let memoryID: String
        let revisions: [RevisionItem]
        let lastHelpedAt: String?
        let lastHelpedSource: String?
        let code: String?
        let validFrom: String?
        let validTo: String?
        let supersededBy: String?
        let writerDevice: String?
        /// The team space a synced-in memory came from, and the account that
        /// contributed it (memory program D16 / P22). Both nil for a personal
        /// memory. `MemoryTimelineView` renders them as the "Team Fact" badge.
        let teamID: String?
        let authorUID: String?
        let source: String
        let revisionBodiesRetained: Bool
        /// The read hit its cap: older events exist and are not in `revisions`.
        let truncated: Bool

        var isRefused: Bool { status == MemoryTimelineRecord.statusRefused }
        var isNotFound: Bool { status == MemoryTimelineRecord.statusNotFound }

        init(
            status: String = MemoryTimelineRecord.statusOK,
            memoryID: String,
            revisions: [RevisionItem] = [],
            lastHelpedAt: String? = nil,
            lastHelpedSource: String? = nil,
            code: String? = nil,
            validFrom: String? = nil,
            validTo: String? = nil,
            supersededBy: String? = nil,
            writerDevice: String? = nil,
            teamID: String? = nil,
            authorUID: String? = nil,
            source: String = MemoryTimelineSource.appAudit,
            revisionBodiesRetained: Bool = false,
            truncated: Bool = false
        ) {
            self.status = status
            self.memoryID = memoryID
            self.revisions = revisions
            self.lastHelpedAt = lastHelpedAt
            self.lastHelpedSource = lastHelpedSource
            self.code = code
            self.validFrom = validFrom
            self.validTo = validTo
            self.supersededBy = supersededBy
            self.writerDevice = writerDevice
            self.teamID = teamID
            self.authorUID = authorUID
            self.source = source
            self.revisionBodiesRetained = revisionBodiesRetained
            self.truncated = truncated
        }

        /// Adapts the app's own audit-ledger record. The member names already
        /// line up, which is the point of having chosen the engine's.
        init(_ record: MemoryTimelineRecord) {
            self.init(
                status: record.status,
                memoryID: record.memoryID,
                revisions: record.revisions.map {
                    RevisionItem(
                        seq: $0.seq,
                        event: $0.event,
                        actor: $0.actor,
                        ts: $0.ts,
                        before: $0.before,
                        after: $0.after,
                        writerDevice: $0.writerDevice,
                        meta: $0.meta
                    )
                },
                lastHelpedAt: record.lastHelpedAt,
                lastHelpedSource: record.lastHelpedSource,
                code: record.code,
                validFrom: record.validFrom,
                validTo: record.validTo,
                supersededBy: record.supersededBy,
                writerDevice: record.writerDevice,
                teamID: record.teamID,
                authorUID: record.authorUID,
                source: record.source,
                revisionBodiesRetained: record.revisionBodiesRetained,
                truncated: record.truncated
            )
        }
    }

    typealias LoadTimeline = (_ memoryID: String, _ projectPath: String?) async throws -> TimelineResult

    let memoryID: String
    let projectPath: String?

    private(set) var revisions: [RevisionItem] = []
    private(set) var lastHelpedAt: String?
    private(set) var lastHelpedSource: String?
    private(set) var validFrom: String?
    private(set) var validTo: String?
    private(set) var supersededBy: String?
    private(set) var writerDevice: String?
    private(set) var teamID: String?
    private(set) var authorUID: String?
    /// Whether `teamID` is on this Mac's own list of teams, resolved ONCE per
    /// load rather than on every render: the list is a `UserDefaults` read and
    /// `teamFactBadge` is a computed property SwiftUI may evaluate freely.
    private(set) var isTeamListedOnThisMac = false
    private(set) var source: String?
    private(set) var revisionBodiesRetained = false
    private(set) var truncated = false
    private(set) var isRefused = false
    private(set) var isNotFound = false
    private(set) var code: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let loadTimeline: LoadTimeline
    private let listedTeamIDs: @MainActor () -> Set<String>

    init(
        memoryID: String,
        projectPath: String? = nil,
        loadTimeline: @escaping LoadTimeline,
        listedTeamIDs: @escaping @MainActor () -> Set<String> = {
            Set(UserDefaultsTeamMembershipDirectory().knownTeamIDs())
        }
    ) {
        self.memoryID = memoryID
        self.projectPath = projectPath
        self.loadTimeline = loadTimeline
        self.listedTeamIDs = listedTeamIDs
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let result: TimelineResult
        do {
            result = try await loadTimeline(memoryID, projectPath)
        } catch {
            // A read that never came back is NOT a memory with no history.
            errorMessage = error.localizedDescription
            return
        }

        source = result.source
        revisionBodiesRetained = result.revisionBodiesRetained
        truncated = result.truncated

        guard !result.isRefused else {
            // Belt and braces: a refusal renders nothing, whatever the server sent.
            isRefused = true
            isNotFound = false
            code = result.code ?? "FOREIGN_PROJECT"
            revisions = []
            lastHelpedAt = nil
            lastHelpedSource = nil
            validFrom = nil
            validTo = nil
            supersededBy = nil
            writerDevice = nil
            teamID = nil
            authorUID = nil
            isTeamListedOnThisMac = false
            truncated = false
            return
        }

        isRefused = false
        isNotFound = result.isNotFound
        code = nil
        revisions = result.revisions.sorted { $0.seq < $1.seq }
        lastHelpedAt = result.lastHelpedAt
        lastHelpedSource = result.lastHelpedSource
        validFrom = result.validFrom
        validTo = result.validTo
        supersededBy = result.supersededBy
        writerDevice = result.writerDevice
        teamID = result.teamID
        authorUID = result.authorUID
        // Resolved here, with the rest of the result, so the badge is a pure
        // read of settled state. Absent team id means the question is not asked.
        isTeamListedOnThisMac = result.teamID.map { listedTeamIDs().contains($0) } ?? false
    }

    /// `Team Fact · contributed by <member>` — shown only when this memory
    /// actually arrived from a team space.
    ///
    /// It reads the SAME two fields PR 3 lands and invents nothing:
    /// `TeamMemoryPullService` writes `teamID` and `authorUID` inside the parked
    /// `payloadJSON`, which is where `writerDevice` already comes from. No
    /// `teamID` means a personal memory, and absence is the honest signal — an
    /// "unknown team" label on every personal row would be noise that says
    /// nothing.
    ///
    /// The member string is the contributor's account id. This lane never learns
    /// a display name (the roster holds uids and no client may read a directory),
    /// so a badge that rendered one would be inventing it.
    ///
    /// A MISSING AUTHOR IS SAID, NOT SUBSTITUTED (PR 4 review L5). The fallback
    /// was the TEAM id, so a fact whose `authorUID` did not survive into the
    /// parked payload read "contributed by team_abcdef0123456789" — an
    /// attribution to something that contributes nothing. The badge still fires
    /// (the row IS a team fact, and reading as personal would be the worse
    /// error); it simply declines to name a contributor it does not have.
    ///
    /// A TEAM THIS MAC NO LONGER LISTS DROPS THE CONTRIBUTOR LINE (PR 4 review
    /// N5). The store's lift is scoped to the member and the `team:` doc-id
    /// prefix and never to the roster, so a fact from a team the member has left
    /// still badges. That is right — the fact did come from there — but rendering
    /// it identically to a live team's fact implies a membership that ended.
    /// See `TeamMemoryCopy.teamFactFormerTeam` for why this reads as a statement
    /// about THIS MAC'S LIST rather than about membership: the list is
    /// `UserDefaultsTeamMembershipDirectory`, a navigation cache the section's
    /// own doc comment calls "not authority", and a cleared cache must not be
    /// rendered as "you left".
    var teamFactBadge: String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        guard isTeamListedOnThisMac else { return TeamMemoryCopy.teamFactFormerTeam }
        guard let member = authorUID.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return TeamMemoryCopy.teamFactUnknownContributor
        }
        return TeamMemoryCopy.teamFactAttribution(member: member)
    }

    // MARK: - What the member is told about the result itself

    /// Says WHICH history this is, and that its revision contents were never
    /// retained — for every state that actually got an answer, not just the one
    /// that got revisions. An empty history and an unknown id are the two states
    /// most likely to be misread as "the engine says nothing changed", so they
    /// are exactly the ones that need the line.
    ///
    /// Nil while loading and after a failed read: a read that never reached a
    /// ledger may not name one.
    var provenanceNote: String? {
        guard let source, isLoading == false, errorMessage == nil else { return nil }
        let ledger = source == MemoryTimelineSource.appAudit
            ? "From this Mac's own memory audit ledger."
            : "From \(source)."
        guard revisionBodiesRetained == false else { return ledger }
        return ledger + " Revision contents are not retained, so what each event changed is not shown."
    }

    /// Present only on a capped read. The window is the LATEST events, so the
    /// note says which end was kept.
    var truncationNote: String? {
        guard truncated else { return nil }
        return "Showing the \(revisions.count) most recent events; older ones are not listed."
    }
}

// MARK: - Model lifetime

/// Keeps ONE `MemoryTimelineModel` alive per memory id, for a view to hold in
/// `@State`.
///
/// `MemoryTimelineModel` loads its history from `.task`, which fires when the
/// view appears and never again. Building the model inside a `@ViewBuilder`
/// therefore throws away a loaded history every time the parent re-evaluates its
/// body — and the review inbox is `@Observable`, so approving or rejecting ANY
/// row re-renders every row. The expanded history would then fall into the
/// `revisions.isEmpty` branch and render "Nothing has happened to this memory
/// yet." about a memory that demonstrably has history: a false statement,
/// produced by the one surface built never to make one.
///
/// The box is a plain reference type on purpose — nothing here is observed, so
/// vending a model during a body evaluation cannot itself invalidate the view.
@MainActor
final class MemoryTimelineModelBox {
    private(set) var memoryID: String?
    private(set) var current: MemoryTimelineModel?

    /// The model for `memoryID`, created once and re-created ONLY when the id
    /// changes — a different memory is a different subject and gets its own
    /// history.
    func model(
        for memoryID: String,
        loadTimeline: @escaping MemoryTimelineModel.LoadTimeline
    ) -> MemoryTimelineModel {
        if let current, self.memoryID == memoryID { return current }
        let fresh = MemoryTimelineModel(memoryID: memoryID, loadTimeline: loadTimeline)
        self.memoryID = memoryID
        self.current = fresh
        return fresh
    }
}
