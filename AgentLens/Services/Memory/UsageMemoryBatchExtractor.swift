import Foundation
import OpenBurnBarCore

// MARK: - Usage Memory Batch Extractor (PR6 Stage 1)
//
// The extractor strategy the `MemoryExtractionWorker` invokes for USAGE batch
// jobs (`job.sourceKind` in `MemorySourceKind.usageKinds`). The usage sibling
// of `ChatTranscriptExtractor`: it conforms to the exact same worker seam
// (`@Sendable (MemoryExtractionJob) async throws -> [MemoryAddRequest]`), so
// the worker's admission/lease/G7/provenance/idempotency discipline applies
// unchanged — no fork.
//
// Flow per job: load the batch's candidate rows (stamped by assembly) → build
// the frozen-prefix prompt → route via `UsageMemoryModelRouter` (snapshot built
// on the MainActor by the engine and read here through a Sendable box) →
//   * local routes  ⇒ `MemoryExtractionLLMClient.callOllama` (strict JSON
//     parse, bounded by the per-job wall clock);
//   * cloud routes  ⇒ `UsageCurationCloudClient` (results map onto the same
//     parsed shape; usage recorded into `UsageCurationTelemetry` +
//     `UsageMemoryBudgetLedger`);
//   * `.queueOnly`  ⇒ throw (the job defers; candidates stay batched).
//
// `hasImageContent` is FALSE for every batch in this PR: image-bearing
// candidates arrive with PR5's Safari payloads, at which point the payload
// grows an image ref and this extractor starts feeding the multimodal lanes.
//
// FAILURE TAXONOMY (deliberately different from chat's "benign empty" posture
// where consuming input is free): a usage job's SUCCESS consumes its
// candidates (they flip `extracted`), so this extractor only returns [] when
// the batch genuinely holds nothing durable (valid-but-empty model output, or
// an empty/unpromptable batch). Anything that prevented a real model verdict —
// no available route, a failed local call, unparseable output, a cloud
// budget/kill error — THROWS so the worker defers the job and the candidates
// stay batched for the retry.

// MARK: Candidate read seam

/// Narrow read seam the extractor needs from the store: the candidate rows of
/// one batch job. `ControlPlaneStore` satisfies it directly; tests inject the
/// same store over an in-memory queue.
protocol UsageExtractionCandidateReading: Sendable {
    func usageCandidates(forBatchJobID jobID: String) async throws -> [UsageMemoryCandidate]
}

extension ControlPlaneStore: UsageExtractionCandidateReading {}

// MARK: Router snapshot box

/// `Sendable`, lock-guarded holder for the latest `UsageMemoryModelRouter`
/// snapshot. Same push/pull discipline as `MemoryExtractionSettingsBox`: the
/// MainActor engine rebuilds the snapshot from settings/gates/ledger before
/// each drain; the off-main extractor pulls it here. `NSLock` for macOS 14.
final class UsageMemoryRouterSnapshotBox: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var snapshot: UsageMemoryModelRouter.Snapshot

    init(_ snapshot: UsageMemoryModelRouter.Snapshot) {
        self.snapshot = snapshot
    }

    func set(_ newValue: UsageMemoryModelRouter.Snapshot) {
        lock.lock()
        snapshot = newValue
        lock.unlock()
    }

    func current() -> UsageMemoryModelRouter.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

// MARK: Errors

/// Typed failures the worker maps onto retry backoffs (see
/// `MemoryExtractionWorker.retryAfter(for:)`).
enum UsageMemoryBatchExtractionError: Error, Equatable {
    /// The router resolved `.queueOnly` (or the local config vanished between
    /// routing and calling): nothing may be sent anywhere. The job defers and
    /// the candidates stay batched.
    case routeUnavailable
    /// The local model call returned no output (endpoint down, timeout, …).
    case localModelFailed
    /// The model produced output that is not the contract JSON (garbage is a
    /// malfunction to retry, NOT a "nothing durable" verdict that would consume
    /// the batch).
    case modelOutputUnusable
}

// MARK: Output parser

/// Strict-JSON parser for the usage extraction contract. Produces the SAME
/// parsed shape the cloud lane returns (`UsageCurationCuratedMemory`), so both
/// lanes share one downstream mapping. `nil` = undecodable output (a model
/// malfunction, thrown upstream); `[]` = valid output with no memories (a real
/// "nothing durable" verdict).
enum UsageMemoryExtractionOutputParser {
    static func parse(_ text: String, maxMemories: Int) -> [UsageCurationCuratedMemory]? {
        guard let payload = decodePayload(from: text) else { return nil }
        let cap = max(0, maxMemories)
        var results: [UsageCurationCuratedMemory] = []
        for raw in payload.memories {
            if results.count >= cap { break }
            guard let memory = validate(raw) else { continue }
            results.append(memory)
        }
        return results
    }

    private static func decodePayload(from text: String) -> RawPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RawPayload.self, from: data) { // try?-ok(malformed model JSON falls through)
            return decoded
        }
        // Bounded brace-slice fallback for prose-wrapped JSON (mirrors
        // `MemoryExtractionParser.decodePayload`).
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end,
              let data = String(trimmed[start ... end]).data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(RawPayload.self, from: data) // try?-ok(prose-wrapped malformed JSON rejected)
    }

    private static func validate(_ raw: RawPayload.Memory) -> UsageCurationCuratedMemory? {
        guard let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false,
              let candidateId = raw.candidateId?.trimmingCharacters(in: .whitespacesAndNewlines),
              candidateId.isEmpty == false else {
            return nil
        }
        let confidence = (raw.confidence?.isFinite == true) ? min(max(raw.confidence ?? 0.5, 0), 1) : 0.5
        return UsageCurationCuratedMemory(
            text: String(text.prefix(MemoryExtractionParser.maxFactChars)),
            kind: raw.kind?.lowercased() ?? "fact",
            confidence: confidence,
            keywords: raw.keywords ?? [],
            tags: raw.tags ?? [],
            context: raw.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            candidateId: candidateId
        )
    }

    private struct RawPayload: Decodable {
        struct Memory: Decodable {
            let text: String?
            let kind: String?
            let confidence: Double?
            let keywords: [String]?
            let tags: [String]?
            let context: String?
            let candidateId: String?

            enum CodingKeys: String, CodingKey {
                case text, kind, confidence, keywords, tags, context, candidateId
            }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { // try?-ok(non-object memory element is dropped)
                    text = nil; kind = nil; confidence = nil
                    keywords = nil; tags = nil; context = nil; candidateId = nil
                    return
                }
                text = try? container.decode(String.self, forKey: .text) // try?-ok(malformed candidate field is dropped)
                kind = try? container.decode(String.self, forKey: .kind) // try?-ok(malformed optional kind falls back)
                confidence = try? container.decode(Double.self, forKey: .confidence) // try?-ok(malformed optional confidence falls back)
                keywords = try? container.decode([String].self, forKey: .keywords) // try?-ok(malformed optional keywords fall back empty)
                tags = try? container.decode([String].self, forKey: .tags) // try?-ok(malformed optional tags fall back empty)
                context = try? container.decode(String.self, forKey: .context) // try?-ok(malformed optional context falls back empty)
                candidateId = try? container.decode(String.self, forKey: .candidateId) // try?-ok(malformed candidate id drops the memory)
            }
        }

        let memories: [Memory]

        enum CodingKeys: String, CodingKey { case memories }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            memories = try container.decode([Memory].self, forKey: .memories)
        }
    }
}

// MARK: Extractor

/// Builds and runs the usage extractor closure. Stateless façade; all per-job
/// state lives in the async call.
struct UsageMemoryBatchExtractor: Sendable {
    private let candidateReader: any UsageExtractionCandidateReading
    private let llmClient: MemoryExtractionLLMClient
    private let cloudClient: any UsageCurationCloudClientProtocol
    private let telemetry: UsageCurationTelemetry
    private let budgetLedger: UsageMemoryBudgetLedger
    private let policy: UsageMemoryExtractionPolicy
    private let settingsProvider: @Sendable () -> MemoryExtractionSettingsSnapshot
    private let routerSnapshotProvider: @Sendable () -> UsageMemoryModelRouter.Snapshot

    init(
        candidateReader: any UsageExtractionCandidateReading,
        llmClient: MemoryExtractionLLMClient = MemoryExtractionLLMClient(),
        cloudClient: any UsageCurationCloudClientProtocol = UsageCurationCloudClient(),
        telemetry: UsageCurationTelemetry,
        budgetLedger: UsageMemoryBudgetLedger,
        policy: UsageMemoryExtractionPolicy = .default,
        settingsProvider: @escaping @Sendable () -> MemoryExtractionSettingsSnapshot,
        routerSnapshotProvider: @escaping @Sendable () -> UsageMemoryModelRouter.Snapshot
    ) {
        self.candidateReader = candidateReader
        self.llmClient = llmClient
        self.cloudClient = cloudClient
        self.telemetry = telemetry
        self.budgetLedger = budgetLedger
        self.policy = policy
        self.settingsProvider = settingsProvider
        self.routerSnapshotProvider = routerSnapshotProvider
    }

    /// The closure shape the worker drains — identical to the chat extractor's.
    func makeExtractor() -> MemoryExtractionWorker.Extractor {
        { job in
            try await self.extract(job)
        }
    }

    func extract(_ job: ControlPlaneStore.MemoryExtractionJob) async throws -> [MemoryAddRequest] {
        try await withThrowingDeadline(seconds: policy.perJobWallClock) {
            try await self.runExtraction(job)
        }
    }

    private func runExtraction(
        _ job: ControlPlaneStore.MemoryExtractionJob
    ) async throws -> [MemoryAddRequest] {
        let candidates = try await candidateReader.usageCandidates(forBatchJobID: job.id)
        // An empty batch (all rows expired/deleted since assembly) holds
        // nothing to extract or retry — benign empty, the job completes.
        guard candidates.isEmpty == false else { return [] }

        let built = UsageMemoryExtractionPromptBuilder.buildPrompt(
            candidates: candidates,
            maxPromptChars: policy.maxPromptChars
        )
        guard built.included.isEmpty == false else { return [] }

        // hasImageContent is false for every PR6 batch — images arrive with
        // PR5's Safari payloads (see the file note).
        let route = UsageMemoryModelRouter.route(
            snapshot: routerSnapshotProvider(),
            hasImageContent: false
        )

        let parsed: [UsageCurationCuratedMemory]
        switch route {
        case .queueOnly:
            throw UsageMemoryBatchExtractionError.routeUnavailable
        case .localText, .localMultimodal:
            // `.localMultimodal` is unreachable while hasImageContent is false;
            // handled as the text path for exhaustiveness.
            parsed = try await extractLocally(prompt: built.prompt)
        case .burnbarCloudText:
            parsed = try await extractViaCloud(lane: .text, candidates: built.included)
        case .burnbarCloudMultimodal:
            parsed = try await extractViaCloud(lane: .multimodal, candidates: built.included)
        }

        return Self.mapToRequests(
            parsed,
            job: job,
            batchCandidateIDs: Set(built.included.map(\.id))
        )
    }

    // MARK: Local route (existing callOllama path)

    private func extractLocally(prompt: String) async throws -> [UsageCurationCuratedMemory] {
        let settings = settingsProvider()
        guard let baseURL = LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL(settings.localBaseURL),
              settings.localModel.isEmpty == false else {
            // The router believed a local model existed but the config is gone
            // (raced a settings change) — defer, never consume the batch.
            throw UsageMemoryBatchExtractionError.routeUnavailable
        }
        let (text, _) = await llmClient.callOllama(
            baseURL: baseURL,
            model: settings.localModel,
            systemPrompt: UsageMemoryExtractionPromptBuilder.systemPrompt,
            userPrompt: prompt,
            timeout: min(max(settings.requestTimeoutSeconds, 1), policy.perJobWallClock),
            maxOutputTokens: policy.maxOutputTokens
        )
        guard let text else { throw UsageMemoryBatchExtractionError.localModelFailed }
        guard let parsed = UsageMemoryExtractionOutputParser.parse(text, maxMemories: policy.maxBatch) else {
            throw UsageMemoryBatchExtractionError.modelOutputUnusable
        }
        return parsed
    }

    // MARK: Cloud routes (U5 client + ledgers)

    private func extractViaCloud(
        lane: UsageCurationLane,
        candidates: [UsageMemoryCandidate]
    ) async throws -> [UsageCurationCuratedMemory] {
        let payload = candidates.compactMap { candidate -> UsageCurationCloudCandidate? in
            guard let decoded = UsageMemoryCandidatePayload.decode(candidate.payloadJSON) else { return nil }
            return UsageCurationCloudCandidate(
                id: candidate.id,
                sourceKind: candidate.sourceKind.rawValue,
                text: decoded.text
            )
        }
        guard payload.isEmpty == false else { return [] }
        // Typed cloud errors (`.budgetExhausted`, `.serverDisabled`, …)
        // propagate to the worker, which maps them onto their deferral windows
        // (+6h / +24h) while the candidates stay batched.
        let response = try await cloudClient.curate(
            lane: lane,
            candidates: payload,
            requestId: UsageCurationCloudClient.newRequestID()
        )
        // Settled call: both belts record the spend (numbers only, no content).
        telemetry.record(usage: response.usage)
        budgetLedger.record(usage: response.usage, lane: response.usage.lane)
        return response.results
    }

    // MARK: Parsed → requests (shared by both lanes)

    /// Map parsed memories to `MemoryAddRequest`s. The model-echoed
    /// `candidateId` is a LOOKUP KEY ONLY: an id outside this batch drops the
    /// memory here (zero resolvable citations ⇒ skipped entirely), and the
    /// worker re-resolves surviving ids against the spool rows when it
    /// recomputes provenance — the same two-layer discipline as chat.
    static func mapToRequests(
        _ parsed: [UsageCurationCuratedMemory],
        job: ControlPlaneStore.MemoryExtractionJob,
        batchCandidateIDs: Set<String>
    ) -> [MemoryAddRequest] {
        parsed.compactMap { memory in
            let candidateID = memory.candidateId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateID.isEmpty == false, batchCandidateIDs.contains(candidateID) else {
                return nil
            }
            let context = memory.context.trimmingCharacters(in: .whitespacesAndNewlines)
            return MemoryAddRequest(
                text: memory.text,
                kind: MemoryKind(rawValue: memory.kind.lowercased()) ?? .fact,
                scope: job.scope,
                confidence: min(max(memory.confidence, 0), 1),
                // Placeholder citation carrying the lookup key; every hash
                // field is recomputed by the worker (sole provenance authority).
                citations: [
                    MemoryCitation(
                        id: "pending-\(candidateID)",
                        threadLogicalID: job.threadLogicalID,
                        messageID: candidateID,
                        role: "",
                        authoredAt: job.createdAt,
                        contentHash: "",
                        occurrence: 0,
                        crossDeviceHMAC: "",
                        citationState: .live
                    )
                ],
                reviewStatus: .quarantined,
                context: context.isEmpty ? nil : context,
                keywords: memory.keywords,
                tags: memory.tags
            )
        }
    }
}
