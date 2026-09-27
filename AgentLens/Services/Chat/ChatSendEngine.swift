import Foundation
import OpenBurnBarKernel

// MARK: - Chat send events

/// Progress events emitted while ``ChatSendEngine`` consumes one backend stream.
///
/// The engine reduces the upstream `CLIChatStreamEvent` flow off the main actor;
/// the `@MainActor` controller iterates this stream and applies each event to UI
/// state. Terminal success arrives as `.finished`; a producer failure rethrows
/// the original error after a final `.transcriptCommitted` flush, preserving the
/// flush-before-rethrow contract pinned by `ChatStreamingMessageMutationTests`.
///
/// `execute(request:pipeline:)` additionally emits the orchestration cases
/// below while driving the pre-stream phases; `consume(_:)` never emits them.
enum ChatSendEvent: Sendable {
    /// Transcript snapshot after the leading/trailing-edge commit throttle.
    case transcriptCommitted(content: String, pieces: [ChatTranscriptPiece])
    /// Structural upstream signal (tool use/result, provider session id).
    case structural(CLIChatStreamEvent)
    /// Terminal success carrying the fully reduced transcript.
    case finished(ChatStreamConsumptionResult)
    /// The selected model cannot route; the controller surfaces `message` as
    /// a red bubble. Terminal: no stream follows.
    case routingFailed(message: String)
    /// Retrieval finished; the controller applies the final jump targets.
    case retrievalCompleted(jumpTargets: [ConversationJumpTarget], hadNoEvidence: Bool)
    /// The local-index oracle settled the turn without an LLM call; the
    /// controller settles the `assistantId` placeholder with `content`. Terminal.
    case oracleSettledLocally(assistantId: String, content: String, jumpTargets: [ConversationJumpTarget])
    /// Prompt assembled and backend stream opened; transcript events follow.
    case streamDispatch(
        assistantId: String,
        streamStartedAt: Date,
        requestModel: String,
        didRouteThroughFusion: Bool
    )
    /// Silent terminal stop: superseded send, or a failure the pipeline phase
    /// already surfaced itself. The controller applies nothing and settles nothing.
    case sendStopped
}

/// Fully reduced transcript of one consumed backend stream.
struct ChatStreamConsumptionResult: Sendable {
    let pieces: [ChatTranscriptPiece]
    let joinedText: String
    let usageSnapshot: CLIUsageSnapshot?
}

// MARK: - Chat send engine

/// Non-`@MainActor` owner of desktop chat stream consumption.
///
/// `ChatSessionController` previously ran the whole token loop — string
/// accumulation, transcript-piece appends, usage max-tracking, and the commit
/// throttle — on the main actor for every chunk. The engine moves that
/// reduction onto a per-stream background actor (`ChatStreamConsumer`); only
/// committed snapshots hop to the main actor for UI application.
///
/// Reduction state is per `consume` call, so a shared engine instance is safe
/// to reuse across sends (which `ChatSessionController` serializes via its
/// `sendInFlight` guard anyway).
actor ChatSendEngine {
    static let shared = ChatSendEngine()

    /// Default commit interval for streamed transcript commits.
    static let defaultCommitInterval: Duration = .milliseconds(80)

    init() {}

    /// Consumes `stream`, returning progress events for the caller to apply.
    ///
    /// The reduction runs on a fresh background actor; the caller iterates the
    /// returned stream from any isolation and applies `.transcriptCommitted`
    /// snapshots and `.structural` signals as they arrive. Normal termination
    /// yields `.finished` and finishes; a producer error yields one final
    /// `.transcriptCommitted` flush and then rethrows the original error.
    nonisolated func consume(
        _ stream: AsyncThrowingStream<CLIChatStreamEvent, Error>,
        commitInterval: Duration = ChatSendEngine.defaultCommitInterval
    ) -> AsyncThrowingStream<ChatSendEvent, Error> {
        let consumer = ChatStreamConsumer(commitInterval: commitInterval)
        return AsyncThrowingStream { continuation in
            Task {
                await consumer.run(upstream: stream, downstream: continuation)
            }
        }
    }

    // MARK: - Send orchestration

    /// Drives one accepted user turn through the full pre-stream sequence —
    /// routing validation, retrieval, jump targets, strategy selection, oracle
    /// execution, evidence formatting, prompt assembly, stream creation — then
    /// consumes the opened stream via `consume(_:)` (spec behaviors 1-10).
    ///
    /// Phase implementations arrive via `pipeline` and run on the main actor;
    /// the engine owns only ordering, branching, and event emission, so every
    /// behavior runs exactly as the inlined `send()` ran it. Terminal success
    /// arrives as `.finished` (preceded by `.streamDispatch`); a producer
    /// failure rethrows the original error after `consume(_:)` performs its
    /// final `.transcriptCommitted` flush. Early exits emit exactly one of
    /// `.routingFailed`, `.oracleSettledLocally`, or `.sendStopped`.
    ///
    /// Every path yields at least one event before finishing, so the caller
    /// can treat the first event as proof the turn left the send gate.
    nonisolated func execute(
        request: ChatSendRequest,
        pipeline: ChatSendPipeline
    ) -> AsyncThrowingStream<ChatSendEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                switch await pipeline.checkRouting() {
                case .proceed:
                    break
                case .stopped:
                    continuation.yield(.sendStopped)
                    continuation.finish()
                    return
                case .failed(let message):
                    continuation.yield(.routingFailed(message: message))
                    continuation.finish()
                    return
                }

                guard let retrieval = await pipeline.runRetrieval(request) else {
                    continuation.yield(.sendStopped)
                    continuation.finish()
                    return
                }
                continuation.yield(.retrievalCompleted(
                    jumpTargets: retrieval.jumpTargets,
                    hadNoEvidence: retrieval.hadNoEvidence
                ))
                if let localMessage = retrieval.localOracleMessage {
                    continuation.yield(.oracleSettledLocally(
                        assistantId: retrieval.assistantId,
                        content: localMessage,
                        jumpTargets: retrieval.jumpTargets
                    ))
                    continuation.finish()
                    return
                }

                guard let opened = await pipeline.openStream(retrieval) else {
                    continuation.yield(.sendStopped)
                    continuation.finish()
                    return
                }
                continuation.yield(.streamDispatch(
                    assistantId: retrieval.assistantId,
                    streamStartedAt: retrieval.streamStartedAt,
                    requestModel: opened.requestModel,
                    didRouteThroughFusion: opened.didRouteThroughFusion
                ))
                do {
                    for try await event in self.consume(opened.stream, commitInterval: request.commitInterval) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    // `consume(_:)` already flushed the partial transcript;
                    // propagate the original error untouched.
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Send-phase pure helpers

    /// Combines the prior user turn with short replies like "yes please" so hybrid search still runs the original question.
    static func retrievalQueryText(for current: String, messages: [ChatMessageRecord]) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortAffirmation(trimmed), messages.count >= 2 else { return trimmed }
        let withoutLatest = messages.dropLast()
        guard let prior = withoutLatest.last(where: { $0.role == .user })?.content else { return trimmed }
        let p = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false, p.caseInsensitiveCompare(trimmed) != .orderedSame else { return trimmed }
        return "\(p) \(trimmed)"
    }

    static func isShortAffirmation(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 { return false }
        let known: Set<String> = [
            "yes", "yes please", "yeah", "yep", "sure", "ok", "okay", "please",
            "do it", "go ahead", "try again", "search", "go for it", "sounds good",
            "please do", "that works", "k", "yup", "absolutely", "please search",
            "do that", "run it"
        ]
        if known.contains(t) { return true }
        if t.hasPrefix("yes ") || t.hasPrefix("sure ") || t.hasPrefix("ok ") { return true }
        return false
    }

    static func burnBarWorkspacePromptSection(path: String) -> String {
        """

        ## OpenBurnBar workspace (required)
        Treat this directory as the root for all new files and for terminal commands that create or modify files, unless the user explicitly names a different absolute path in their message:
        \(path)

        Change to this directory before running shell commands that write files. Write every new file under this path (subdirectories are allowed).
        A `openburnbar-mcp.config.json` may be present to wire OpenBurnBar’s local index into MCP-capable tools.
        """
    }
}

// MARK: - Per-stream consumer

/// Reduction state for one consumed backend stream.
///
/// One instance per `consume` call, so concurrent consumes never share mutable
/// state. Owns the leading + trailing edge commit throttle: a chunk that lands
/// inside the commit interval arms a single trailing flush for the remainder of
/// the interval, bounding visible-transcript staleness at the interval even
/// when the producer then pauses (slow model, long tool call).
private actor ChatStreamConsumer {
    private let commitInterval: Duration
    private var pieces: [ChatTranscriptPiece] = []
    private var joinedText = ""
    private var usageSnapshot: CLIUsageSnapshot?
    private var lastCommit: ContinuousClock.Instant
    private var trailingFlush: Task<Void, Never>?

    init(commitInterval: Duration) {
        self.commitInterval = commitInterval
        self.lastCommit = ContinuousClock.now - commitInterval
    }

    func run(
        upstream: AsyncThrowingStream<CLIChatStreamEvent, Error>,
        downstream: AsyncThrowingStream<ChatSendEvent, Error>.Continuation
    ) async {
        // The success and rethrow routes both end in `flush()`, which disarms
        // the trailing task; this covers the third exit — a cancelled parent
        // task — so no armed flush ever outlives the stream.
        defer { cancelTrailingFlush() }
        do {
            for try await event in upstream {
                var forceCommit = false
                switch event {
                case .text(let chunk):
                    forceCommit = pieces.isEmpty
                    ChatTranscriptPiece.appendStreamingText(chunk, to: &pieces)
                    joinedText += chunk
                case .reasoning(let chunk):
                    forceCommit = pieces.isEmpty
                    ChatTranscriptPiece.appendStreamingChunk(chunk, kind: .reasoning, to: &pieces)
                case .refusal(let chunk):
                    forceCommit = pieces.isEmpty
                    ChatTranscriptPiece.appendStreamingChunk(chunk, kind: .refusal, to: &pieces)
                case .toolUse(let name, let detail):
                    pieces.append(ChatTranscriptPiece(kind: .toolUse, value: name, detail: detail))
                    forceCommit = true
                    downstream.yield(.structural(event))
                case .toolResult(let name, let detail):
                    pieces.append(ChatTranscriptPiece(kind: .toolResult, value: name, detail: detail))
                    forceCommit = true
                    downstream.yield(.structural(event))
                case .usage(let usage):
                    if let previous = usageSnapshot {
                        usageSnapshot = usage.totalTokens >= previous.totalTokens ? usage : previous
                    } else {
                        usageSnapshot = usage
                    }
                    continue
                case .sessionID:
                    downstream.yield(.structural(event))
                    continue
                }

                await record(force: forceCommit, downstream: downstream)
            }
        } catch {
            await flush(downstream: downstream)
            downstream.finish(throwing: error)
            return
        }

        await flush(downstream: downstream)
        downstream.yield(.finished(ChatStreamConsumptionResult(
            pieces: pieces,
            joinedText: joinedText,
            usageSnapshot: usageSnapshot
        )))
        downstream.finish()
    }

    /// Records staged transcript state. Commits immediately when `force` is set
    /// or the interval has elapsed; otherwise arms a single trailing flush for
    /// the remainder of the interval.
    private func record(
        force: Bool,
        downstream: AsyncThrowingStream<ChatSendEvent, Error>.Continuation
    ) async {
        let now = ContinuousClock.now
        guard force || now - lastCommit >= commitInterval else {
            armTrailingFlush(after: commitInterval - (now - lastCommit), downstream: downstream)
            return
        }
        await flush(downstream: downstream)
    }

    /// Commits the staged state now and disarms any pending trailing flush, so
    /// a settled stream can never be followed by a late commit.
    private func flush(
        downstream: AsyncThrowingStream<ChatSendEvent, Error>.Continuation
    ) async {
        cancelTrailingFlush()
        lastCommit = ContinuousClock.now
        downstream.yield(.transcriptCommitted(content: joinedText, pieces: pieces))
    }

    private func cancelTrailingFlush() {
        trailingFlush?.cancel()
        trailingFlush = nil
    }

    private func armTrailingFlush(
        after delay: Duration,
        downstream: AsyncThrowingStream<ChatSendEvent, Error>.Continuation
    ) {
        // A flush already scheduled for this interval covers every chunk staged
        // since — re-arming would only move the same commit later.
        guard trailingFlush == nil else { return }
        trailingFlush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.completeTrailingFlush(downstream: downstream)
        }
    }

    private func completeTrailingFlush(
        downstream: AsyncThrowingStream<ChatSendEvent, Error>.Continuation
    ) async {
        // Clear first so `flush()`'s cancel() cannot target the very task
        // that is running it.
        trailingFlush = nil
        await flush(downstream: downstream)
    }
}
