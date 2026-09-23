import Foundation
import OpenBurnBarKernel

// MARK: - Memory, chat, and snapshot lane wrappers (Wave 2.1 cutover)
//
// One thin wrapper per daemon-owned table cluster: the pre-existing
// `daemon.memory.*` surface plus the single-writer lane wrappers. Each
// routes an app-side call through the typed RPC instead of touching
// SQLite directly; reads stay on the app's local connection until the
// read cutover. Split out of OpenBurnBarDaemonSocketClient.swift, which
// the Swift file-size budget holds shrink-only. Shares the client's
// internal `requestResult`/`send` transport.

extension OpenBurnBarDaemonSocketClient {
    // MARK: - Chat history (Wave 2.1 single-writer cutover)

    /// The daemon owns `chat_threads` / `chat_messages`; the app routes all
    /// chat writes through these wrappers instead of touching the tables
    /// directly. Reads stay on the app's local connection for now.
    static func chatThreadCreate(
        _ request: BurnBarChatThreadCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarChatThreadCreateResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .chatThreadCreate,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func chatThreadList(
        _ request: BurnBarChatThreadListRequest,
        at socketURL: URL
    ) throws -> BurnBarChatThreadListResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .chatThreadList,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func chatThreadGet(
        _ request: BurnBarChatThreadGetRequest,
        at socketURL: URL
    ) throws -> BurnBarChatThreadGetResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .chatThreadGet,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func chatMessageAppend(
        _ request: BurnBarChatMessageAppendRequest,
        at socketURL: URL
    ) throws -> BurnBarChatMessageAppendResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .chatMessageAppend,
                params: request
            ),
            socketURL: socketURL
        )
    }

    /// The daemon owns `project_memory_snapshots`; the app routes its snapshot
    /// writes through these wrappers instead of touching the table directly.
    /// Reads stay on the app's local connection for now.
    static func projectMemorySnapshotUpsert(
        _ request: BurnBarProjectMemorySnapshotUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarProjectMemorySnapshotUpsertResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memorySnapshotUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func projectMemorySnapshotDelete(
        _ request: BurnBarProjectMemorySnapshotDeleteRequest,
        at socketURL: URL
    ) throws -> BurnBarProjectMemorySnapshotDeleteResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memorySnapshotDelete,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func projectMemorySnapshotDeleteAll(
        at socketURL: URL
    ) throws -> BurnBarProjectMemorySnapshotDeleteAllResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memorySnapshotDeleteAll,
                params: BurnBarProjectMemorySnapshotDeleteAllRequest()
            ),
            socketURL: socketURL
        )
    }

    /// The daemon owns the memory authority tables; the app routes its
    /// finalized memory write sets through this wrapper instead of touching
    /// the tables directly. Reads stay on the app's local connection for now.
    static func memoryAuthorityApply(
        _ request: BurnBarMemoryAuthorityApplyRequest,
        at socketURL: URL
    ) throws -> BurnBarMemoryAuthorityApplyResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryAuthorityApply,
                params: request
            ),
            socketURL: socketURL
        )
    }

    /// The daemon owns `vector_index_snapshots`; the app routes its HNSW
    /// snapshot-lifecycle writes through this wrapper instead of touching the
    /// table directly. Reads stay on the app's local connection for now.
    static func vectorIndexSnapshotUpsert(
        _ request: BurnBarVectorIndexSnapshotUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarVectorIndexSnapshotUpsertResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .searchVectorSnapshotUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    // MARK: - Memory lanes (pre-existing daemon.memory.* surface)

    /// Per-project memory counters from the daemon's own store — which is this
    /// app's database, indexed by the daemon at
    /// `OpenBurnBarAppPaths.live(...).databaseURL`.
    ///
    /// `daemon.memory.analytics` already exists, already maps to the
    /// `memory_read` capability, and is already `.full` for the `.app` peer, so
    /// this is a client method and nothing more: no new RPC id, no new contract,
    /// no new capability. `projectPath` is resolved to a project identity
    /// DAEMON-side — the app never guesses one — and nil asks about the daemon's
    /// own default project.
    ///
    /// A refusing or unreachable daemon THROWS. It must never degrade to a
    /// zeroed response: "we could not ask" and "this project has no memories"
    /// are different statements, and only one of them is ever observed here.
    static func memoryAnalytics(
        projectPath: String?,
        at socketURL: URL
    ) throws -> BurnBarProjectMemoryAnalyticsResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProjectMemoryAnalyticsResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryAnalytics,
                params: BurnBarProjectMemoryAnalyticsRequest(projectPath: projectPath)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result
    }

    /// Hand one review verdict to the daemon so IT publishes the body.
    ///
    /// The app writes its own `memory.approve` / `memory.reject` audit row and
    /// flips `review_status` in the shared `agent_memories` table, but moving a
    /// quarantined body into the project-memory snapshot and refilling the
    /// syncable `body_hash` is the daemon's `setReviewStatus` and nothing else's
    /// (I-56: the daemon stays the single publisher). This is the call that asks
    /// it to, and it is the same RPC the Linux desktop's review surface and the
    /// `burnbar_memory_review` MCP tool already use — no new RPC id, no new
    /// contract, no new capability (`memory_write` is already `.full` for the
    /// `.app` peer).
    ///
    /// `projectPath` is the root the DAEMON itself recorded in `pcm_projects`,
    /// read back out of the shared database: the daemon resolves a path through
    /// the WRITING resolver, so any other string would register a project rather
    /// than address one.
    ///
    /// A refusing or unreachable daemon THROWS. The approval itself already
    /// happened — the caller keeps it and shows the row as awaiting publication
    /// — but this method never reports a publication that did not occur.
    ///
    /// `expectedUpdatedAt` carries the `updated_at` stamp the caller wrote when
    /// it committed the verdict locally (review #2565): two overlapping verdicts
    /// race on the wire, and the stamp is what lets the daemon refuse to
    /// resurrect a Reject an earlier Approve RPC would have overwritten. The
    /// response's `applied` is `false` on that refusal, with `status` naming the
    /// verdict that actually won.
    static func memoryReviewStatus(
        memoryID: String,
        projectPath: String,
        status: MemoryReviewStatus,
        expectedUpdatedAt: String? = nil,
        at socketURL: URL
    ) throws -> BurnBarProjectMemoryReviewStatusResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProjectMemoryReviewStatusResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryReviewStatus,
                params: BurnBarProjectMemoryReviewStatusRequest(
                    memoryID: memoryID,
                    projectPath: projectPath,
                    status: status,
                    expectedUpdatedAt: expectedUpdatedAt
                )
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result
    }

    /// The daemon's hard forget for an agent-lane memory (review #2565): it
    /// removes the quarantine body, the published project-memory section, and
    /// the engine-side mirror — the halves the app's local delete cannot reach.
    /// The app calls this BEFORE removing its `agent_memories` authority row,
    /// because the daemon needs the row's `project_id` to locate the body, and
    /// it fails closed: a throwing call leaves every local byte in place.
    ///
    /// `requireCloudDelete` stays `false` — the daemon cannot mint the
    /// member-keyed cloud tombstone; the app's own forget lane writes it.
    static func memoryForget(
        memoryID: String,
        projectPath: String,
        at socketURL: URL
    ) throws -> BurnBarProjectMemoryForgetResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProjectMemoryForgetResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryForget,
                params: BurnBarProjectMemoryForgetRequest(
                    memoryID: memoryID,
                    projectPath: projectPath,
                    requireCloudDelete: false
                )
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result
    }
}
