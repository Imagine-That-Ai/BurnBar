import Foundation
import Observation

/// View-model backing `MemoryTimelineView`.
///
/// B8: presents one memory's project-scoped revision history — ordered
/// revisions, the device that wrote each one, and when the memory last helped.
///
/// **PARKED — no host, no data path.** Nothing in the app constructs this model:
/// the app talks only to the daemon, and the daemon exposes no timeline RPC. The
/// engine's `MemoryReader.timeline` (`tools/openburnbar-mcp/memory_engine/_read.py`)
/// serves the MCP surface only. Mounting this needs a `daemon.memory.timeline`
/// RPC that forwards the engine read; until then this file and its tests are held
/// on `wip/memory-app-views-awaiting-daemon-rpcs` rather than shipped dead.
///
/// **Wire contract — the ENGINE'S REAL SHAPE, verified against `_read.py`.**
/// The model as written below does *not* match it; three member names differ, and
/// whoever mounts this must adapt the decoder (or rename the model's members) at
/// that point. Recorded here verbatim so the adaptation is mechanical:
///
/// ```jsonc
/// {
///   "status": "ok",                       // "ok" | "not_found" | "refused"
///   "code": "FOREIGN_PROJECT",            // ON REFUSAL ONLY — named `code`,
///                                         // NOT `refusalCode`
///   "memoryID": "mem_…",                  // the RESOLVED id; an alias read also
///                                         // carries "aliasedFrom": "<asked id>"
///   "lastHelpedAt": "2026-09-05T10:30:00Z",   // null when neither source has a row
///   "lastHelpedSource": "recall_serve",   // "recall_serve" | "history" | null
///   "revisions": [                        // ordered by seq ASC, capped at 500
///     {
///       "seq": 1,                         // memory_history ordering key
///       "event": "created",               // memory_history.event, verbatim
///       "actor": "user",
///       "ts": "2026-09-05T10:00:00Z",     // named `ts`, NOT `timestamp`
///       "before": null,                   // decrypted under AAD "<id>|<project>|history"
///       "after": "…",
///       "meta": { … },                    // the whole meta_json DICT, NOT a
///                                         // pre-rendered `metaSummary` string
///       "writerDevice": "macbook-air",    // meta writerDevice/writer_device/deviceId/device_id
///       "extractedBy": null,              // meta extracted_by/extractedBy (P19)
///       "modelId": null                   // meta model_id/modelId (P19)
///     }
///   ],
///   // plus `project_payload(project_id, root)`: projectID / projectName / projectRoot,
///   // present on every branch including `not_found` and `refused`.
/// }
/// ```
///
/// Deltas to close at mount time: `ts` → `timestamp`, `meta` (dict) → whatever
/// summary the row renders, `code` → `refusalCode`. `status` gains a third value,
/// `not_found`, which this model would currently treat as a successful empty read
/// — it must be distinguished from `ok` before this renders.
///
/// A refusal must carry **no** revisions, body, or meta: a foreign memory id
/// leaks nothing, not even its shape. The engine already enforces that; the model
/// enforces it locally too, so a server that refused-but-still-answered cannot
/// render anything.
@Observable @MainActor
final class MemoryTimelineModel {

    /// One revision in the memory timeline.
    struct RevisionItem: Identifiable, Equatable {
        let seq: Int
        let event: String
        let actor: String
        let timestamp: String
        let before: String?
        let after: String?
        let writerDevice: String?
        let metaSummary: String?

        var id: Int { seq }

        init(
            seq: Int,
            event: String,
            actor: String,
            timestamp: String,
            before: String? = nil,
            after: String? = nil,
            writerDevice: String? = nil,
            metaSummary: String? = nil
        ) {
            self.seq = seq
            self.event = event
            self.actor = actor
            self.timestamp = timestamp
            self.before = before
            self.after = after
            self.writerDevice = writerDevice
            self.metaSummary = metaSummary
        }

        /// Title case for the known events; anything the engine adds later
        /// renders capitalised rather than disappearing.
        var displayEvent: String {
            switch event {
            case "created": "Created"
            case "updated": "Updated"
            case "retired": "Retired"
            case "reactivated": "Reactivated"
            case "synced": "Synced"
            default: event.capitalized
            }
        }
    }

    /// One timeline read, as the loader returns it.
    struct TimelineResult: Equatable {
        let status: String
        let memoryID: String
        let revisions: [RevisionItem]
        let lastHelpedAt: String?
        let lastHelpedSource: String?
        let refusalCode: String?

        var isRefused: Bool { status == "refused" }

        init(
            status: String = "ok",
            memoryID: String,
            revisions: [RevisionItem] = [],
            lastHelpedAt: String? = nil,
            lastHelpedSource: String? = nil,
            refusalCode: String? = nil
        ) {
            self.status = status
            self.memoryID = memoryID
            self.revisions = revisions
            self.lastHelpedAt = lastHelpedAt
            self.lastHelpedSource = lastHelpedSource
            self.refusalCode = refusalCode
        }
    }

    typealias LoadTimeline = (_ memoryID: String, _ projectPath: String?) async throws -> TimelineResult

    let memoryID: String
    let projectPath: String?

    private(set) var revisions: [RevisionItem] = []
    private(set) var lastHelpedAt: String?
    private(set) var lastHelpedSource: String?
    private(set) var isRefused = false
    private(set) var refusalCode: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let loadTimeline: LoadTimeline

    init(
        memoryID: String,
        projectPath: String? = nil,
        loadTimeline: @escaping LoadTimeline
    ) {
        self.memoryID = memoryID
        self.projectPath = projectPath
        self.loadTimeline = loadTimeline
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
            errorMessage = error.localizedDescription
            return
        }

        guard !result.isRefused else {
            // Belt and braces: a refusal renders nothing, whatever the server sent.
            isRefused = true
            refusalCode = result.refusalCode ?? "FOREIGN_PROJECT"
            revisions = []
            lastHelpedAt = nil
            lastHelpedSource = nil
            return
        }

        isRefused = false
        refusalCode = nil
        revisions = result.revisions.sorted { $0.seq < $1.seq }
        lastHelpedAt = result.lastHelpedAt
        lastHelpedSource = result.lastHelpedSource
    }
}
