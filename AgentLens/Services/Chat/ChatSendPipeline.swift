import Foundation

// MARK: - Send orchestration pipeline

/// Snapshot of one accepted user turn handed to ``ChatSendEngine/execute(request:pipeline:)``.
///
/// The controller builds this on the main actor after committing the user
/// message; everything in it is a value, so the engine can drive the whole
/// pre-stream sequence off the main actor and hop back only inside the
/// pipeline closures.
struct ChatSendRequest: Sendable {
    /// The trimmed composer text for this turn.
    let trimmed: String
    /// Commit throttle for the streamed transcript reduction.
    let commitInterval: Duration
}

/// Outcome of the route + backend-availability phase (spec behavior 1).
enum ChatSendRoutingOutcome: Sendable {
    /// Validation passed; the engine proceeds to retrieval.
    case proceed
    /// Validation failed and already surfaced its own red bubble (backend
    /// availability); the engine stops silently without settling.
    case stopped
    /// The selected model cannot route; the engine emits
    /// `.routingFailed` so the controller can surface `message`.
    case failed(message: String)
}

/// Everything later send phases need from retrieval (spec behaviors 2-6).
///
/// Produced on the main actor by the retrieval pipeline phase, which paints
/// the thinking placeholder before running any query — exactly as the
/// inlined `send()` did — then crossed into the engine as a value.
struct ChatSendRetrieval: Sendable {
    /// The trimmed user turn, threaded through for prompt assembly and the
    /// single-turn CLI backends.
    let trimmed: String
    /// Transcript the model should see, captured before the placeholder.
    let promptHistory: [ChatMessageRecord]
    let assistantId: String
    let streamStartedAt: Date
    /// Search service captured at retrieval time, so a mid-send
    /// `reconfigureSearchService()` cannot swap prompt inputs under the turn.
    let searchService: SearchService?
    let retrievalResults: [RetrievalResult]
    let queryRun: OpenBurnBarQueryRunResult
    let oracleContextSection: String
    /// Final jump targets (post-oracle replacement) for the UI to apply.
    let jumpTargets: [ConversationJumpTarget]
    let hadNoEvidence: Bool
    /// Non-nil when the local-index oracle settled the turn without an LLM
    /// call; the engine emits `.oracleSettledLocally` instead of dispatching.
    let localOracleMessage: String?
}

/// An opened backend stream plus the dispatch facts the settle phase needs
/// (spec behaviors 7-9: evidence formatting, prompt assembly, stream creation).
struct ChatSendOpenedStream: Sendable {
    let stream: AsyncThrowingStream<CLIChatStreamEvent, Error>
    let requestModel: String
    let didRouteThroughFusion: Bool
}

/// Phase implementations injected into the send engine.
///
/// Each phase runs on the main actor (it touches `DataStore`, `CLIBridge`,
/// or `SettingsManager`, all `@MainActor` facades) while the engine owns the
/// sequencing, branching, and event emission. Closures capture the controller
/// weakly: when it is gone they report a silent stop so the producer task
/// finishes instead of retaining a dead UI.
struct ChatSendPipeline: Sendable {
    /// Phase 2: route + backend availability. See `ChatSendRoutingOutcome`.
    var checkRouting: @MainActor @Sendable () async -> ChatSendRoutingOutcome
    /// Phase 3: paint placeholder, run retrieval, build jump targets, run the
    /// oracle. Returns nil when superseded (silent stop, no settle).
    var runRetrieval: @MainActor @Sendable (ChatSendRequest) async -> ChatSendRetrieval?
    /// Phases 4-5: assemble the prompt, resolve fusion, open the backend
    /// stream. Returns nil when superseded before dispatch (silent stop).
    var openStream: @MainActor @Sendable (ChatSendRetrieval) async -> ChatSendOpenedStream?
}
