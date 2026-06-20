import Foundation
import OpenBurnBarCore

// MARK: - Chat Transcript Extractor
//
// Builds the `MemoryExtractionWorker.Extractor` closure: the
// `@Sendable (MemoryExtractionJob) async throws -> [MemoryAddRequest]` the worker
// drains. Owns the LLM call path (mirrors `SummaryWorker`'s provider loop: local/MLX
// first, then cloud providers gated by the daily cost cap), strict-JSON parsing, and
// the G7 candidate-DROP gate. It is the input/transform stage only — the worker is the
// sole provenance authority (PR-D1 must-fix #1/#3) and recomputes every citation hash
// after this closure returns, so the citations produced here carry ONLY the model's
// claimed `messageID` (a lookup key) with placeholder hashes the worker overwrites.
//
// FAILURE TAXONOMY (PR-D1 must-fix, kept from spec):
//   * Return `[]` (job SUCCEEDS) on benign empties: transcript not found, empty
//     transcript, empty/garbage model output, all candidates dropped by the gate, or
//     every provider unavailable/uncalled. There is nothing to retry — re-running the
//     same transcript yields the same empty, and a "failed" status would spin the
//     retry loop forever on a transcript that simply has no durable memory.
//   * THROW only on a genuine transient infra fault we expect to clear (the cost-cap
//     spend read failing). The worker marks the job failed with a retry backoff.
//
// WALL-CLOCK BOUND (PR-D1 must-fix #5): the whole extraction is raced against a
// deadline strictly below the 15-min job lease, so an in-flight extraction can never
// outlive its lease and be reclaimed + double-processed by a second drain.

/// Read seam the extractor needs from the control-plane store: the transcript for a
/// job's thread. Narrow on purpose so the extractor is decoupled from the full store
/// surface and testable with a fake.
protocol ChatExtractionTranscriptReading: Sendable {
    func fetchChatTranscriptForExtraction(threadID: String) async throws -> [ChatTranscriptMessage]
}

// The cloud daily-cap spend read reuses the summary feature's `SummaryDailySpendReading`
// seam (identical fail-closed signature) so memory and summary share ONE spend source;
// a failed read must never default to 0 and silently bypass the cap.

/// One transcript message the extractor reasons over and the worker later cites. The
/// `body` is the canonical text the citation's `contentHash` will be computed from.
struct ChatTranscriptMessage: Sendable, Equatable {
    let id: String
    let role: String
    let body: String
    let authoredAt: Date
}

/// Builds and runs the extractor closure. Stateless façade; all per-job state lives in
/// the async call.
struct ChatTranscriptExtractor: Sendable {
    /// Hard upper bound on total extraction wall-clock, strictly below the worker's
    /// 15-min lease (`MemoryExtractionJob.defaultLeaseDuration`). Asserted by a test.
    /// Chosen with a wide safety margin: extraction is one short LLM round-trip, not a
    /// long job, so 4 minutes is generous while leaving >10 min of lease headroom.
    static let maxWallClock: TimeInterval = 4 * 60

    private let transcriptReader: any ChatExtractionTranscriptReading
    private let spendReader: any SummaryDailySpendReading
    private let llmClient: MemoryExtractionLLMClient
    private let keyResolver: MemoryExtractionAPIKeyResolver
    private let settingsProvider: @Sendable () -> MemoryExtractionSettingsSnapshot

    init(
        transcriptReader: any ChatExtractionTranscriptReading,
        spendReader: any SummaryDailySpendReading,
        llmClient: MemoryExtractionLLMClient = MemoryExtractionLLMClient(),
        keyResolver: MemoryExtractionAPIKeyResolver,
        settingsProvider: @escaping @Sendable () -> MemoryExtractionSettingsSnapshot
    ) {
        self.transcriptReader = transcriptReader
        self.spendReader = spendReader
        self.llmClient = llmClient
        self.keyResolver = keyResolver
        self.settingsProvider = settingsProvider
    }

    /// The closure the worker stores. Captures `self` (a `Sendable` value).
    func makeExtractor() -> MemoryExtractionWorker.Extractor {
        { job in
            try await self.extract(job)
        }
    }

    // MARK: - Extraction

    func extract(_ job: ControlPlaneStore.MemoryExtractionJob) async throws -> [MemoryAddRequest] {
        try await withThrowingDeadline(seconds: Self.maxWallClock) {
            try await self.runExtraction(job)
        }
    }

    private func runExtraction(_ job: ControlPlaneStore.MemoryExtractionJob) async throws -> [MemoryAddRequest] {
        let settings = settingsProvider()

        // Load the transcript for the job's thread. A read fault here is transient
        // infra → throw so the worker retries. An *empty* transcript is benign → [].
        let transcript = try await transcriptReader.fetchChatTranscriptForExtraction(threadID: job.threadID)
        guard transcript.isEmpty == false else { return [] }

        // The terminal commit that triggered extraction must be present; if the cited
        // message id is gone, there is nothing durable to anchor — benign empty.
        guard transcript.contains(where: { $0.id == job.messageID }) else { return [] }

        let lines = transcript.map { message in
            MemoryExtractionPromptBuilder.TranscriptLine(
                messageID: message.id,
                role: message.role,
                text: message.body
            )
        }
        let userPrompt = MemoryExtractionPromptBuilder.buildPrompt(
            lines: lines,
            maxChars: settings.maxPromptChars
        )
        guard userPrompt.isEmpty == false else { return [] }

        guard let rawOutput = await callModel(
            systemPrompt: MemoryExtractionPromptBuilder.systemPrompt,
            userPrompt: userPrompt,
            settings: settings
        ) else {
            // No provider produced output (all unavailable / uncalled / over cap).
            // Nothing to persist and nothing transient to retry → benign empty.
            return []
        }

        let candidates = MemoryExtractionParser.parse(
            rawOutput,
            maxCandidates: settings.maxCandidatesPerJob
        )
        guard candidates.isEmpty == false else { return [] }

        let transcriptIDs = Set(transcript.map(\.id))
        return mapCandidatesToRequests(
            candidates,
            job: job,
            transcriptIDs: transcriptIDs
        )
    }

    // MARK: - Candidate → request mapping (with G7 DROP gate)

    /// Map validated candidates to `MemoryAddRequest`s, applying the G7 gate as a
    /// per-candidate DROP filter (PR-D1 must-fix #4) so one secret-bearing candidate
    /// does not poison the rest of the batch. Provenance is intentionally a stub here;
    /// the worker recomputes it.
    private func mapCandidatesToRequests(
        _ candidates: [ExtractedMemoryCandidate],
        job: ControlPlaneStore.MemoryExtractionJob,
        transcriptIDs: Set<String>
    ) -> [MemoryAddRequest] {
        var requests: [MemoryAddRequest] = []
        for candidate in candidates {
            // G7 candidate-DROP gate. `.reject` (default, fail-closed) is also what an
            // unavailable corpus returns, so a missing corpus drops every candidate
            // rather than leaking one. Only `.allow` (nothing found) passes.
            guard case .allow = MemorySecretPIIGate.evaluate(candidate.text, policy: .reject) else {
                continue
            }

            // Thread ONLY the model's claimed message id through as a lookup key. If it
            // is not in the transcript, carry no citation at all (never fabricate); the
            // worker drops unresolvable citations too, but filtering here keeps the
            // placeholder honest and avoids handing the worker a known-bad id.
            let citations = provenanceStub(for: candidate, job: job, transcriptIDs: transcriptIDs)

            requests.append(
                MemoryAddRequest(
                    text: candidate.text,
                    kind: candidate.kind,
                    scope: job.scope,
                    confidence: candidate.confidence,
                    citations: citations,
                    reviewStatus: .quarantined
                )
            )
        }
        return requests
    }

    /// A single placeholder citation carrying the claimed (and transcript-present)
    /// message id. Every hash field is a deterministic placeholder the worker
    /// OVERWRITES; nothing here is trusted as provenance.
    private func provenanceStub(
        for candidate: ExtractedMemoryCandidate,
        job: ControlPlaneStore.MemoryExtractionJob,
        transcriptIDs: Set<String>
    ) -> [MemoryCitation] {
        guard let claimed = candidate.claimedMessageID, transcriptIDs.contains(claimed) else {
            return []
        }
        return [
            MemoryCitation(
                id: "pending-\(claimed)",
                threadLogicalID: job.threadLogicalID,
                messageID: claimed,
                role: "",
                authoredAt: job.createdAt,
                contentHash: "",
                occurrence: 0,
                crossDeviceHMAC: "",
                citationState: .live
            )
        ]
    }

    // MARK: - Provider loop (local-first, cost-capped)

    /// Try providers in `settings.providerOrder`. Local/MLX never read a key and never
    /// hit the cap; cloud providers are gated by the fail-closed spend read + daily
    /// cap (mirrors `SummaryWorker`). Returns the first non-nil raw model output.
    private func callModel(
        systemPrompt: String,
        userPrompt: String,
        settings: MemoryExtractionSettingsSnapshot
    ) async -> String? {
        for provider in settings.providerOrder {
            if Task.isCancelled { return nil }
            if let output = await callProvider(
                provider,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            ) {
                return output
            }
        }
        return nil
    }

    private func callProvider(
        _ provider: SummaryProviderID,
        systemPrompt: String,
        userPrompt: String,
        settings: MemoryExtractionSettingsSnapshot
    ) async -> String? {
        switch provider {
        case .local:
            let (text, _) = await llmClient.callOllama(
                baseURL: settings.localBaseURL,
                model: settings.localModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                timeout: settings.requestTimeoutSeconds,
                maxOutputTokens: settings.maxOutputTokens
            )
            return text

        case .mlx:
            let base = normalizedBase(settings.mlxBaseURL)
            guard base.isEmpty == false, settings.mlxModel.isEmpty == false else { return nil }
            return await callOpenAICompatible(
                provider: .mlx,
                baseURL: base + "/v1",
                apiKey: "",
                model: settings.mlxModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )

        case .minimax:
            guard let key = await keyResolver.resolveAPIKey(for: .minimax) else { return nil }
            return await callOpenAICompatible(
                provider: .minimax,
                baseURL: "https://api.minimax.io/v1",
                apiKey: key,
                model: settings.minimaxModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )

        case .openrouter:
            guard let key = await keyResolver.resolveAPIKey(for: .openrouter) else { return nil }
            let models = [settings.openRouterPrimaryModel, settings.openRouterFallbackModel]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            for model in models {
                if let output = await callOpenAICompatible(
                    provider: .openrouter,
                    baseURL: "https://openrouter.ai/api/v1",
                    apiKey: key,
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    openRouterHeaders: true,
                    settings: settings
                ) {
                    return output
                }
            }
            return nil

        case .zai:
            guard let key = await keyResolver.resolveAPIKey(for: .zai) else { return nil }
            return await callOpenAICompatible(
                provider: .zai,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                apiKey: key,
                model: settings.zaiModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )

        case .ollama:
            let base = normalizedBase(settings.ollamaBaseURL)
            guard base.isEmpty == false, settings.ollamaModel.isEmpty == false else { return nil }
            let apiKey = await keyResolver.resolveAPIKey(for: .ollama)
            return await callOpenAICompatible(
                provider: .ollama,
                baseURL: base + "/v1",
                apiKey: apiKey ?? "",
                model: settings.ollamaModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        }
    }

    /// OpenAI-compatible call wrapper that enforces the cloud daily cap with a
    /// fail-closed spend read (mirrors `SummaryWorker.summarizeWithOpenAICompatibleProvider`).
    private func callOpenAICompatible(
        provider: SummaryProviderID,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        openRouterHeaders: Bool = false,
        settings: MemoryExtractionSettingsSnapshot
    ) async -> String? {
        guard model.isEmpty == false else { return nil }

        if provider != .local, provider != .mlx {
            let estimatedInputTokens = max(userPrompt.count / 4, 1)
            let estimatedOutputTokens = max(settings.maxOutputTokens / 2, 100)
            let estimatedCost = SummaryCostEstimator.estimateCostUSD(
                provider: provider,
                model: model,
                inputTokens: estimatedInputTokens,
                outputTokens: estimatedOutputTokens
            )
            // Fail-closed: a failed spend read skips the paid call rather than
            // defaulting to 0 and silently blowing past the cap.
            let spentToday: Double
            do {
                spentToday = try await spendReader.summarySpendToday(now: Date())
            } catch {
                AppLogger.dataStore.silentFailure(
                    "memory_extraction_spend_read_failed_fail_closed",
                    error: error,
                    context: ["provider": provider.rawValue, "model": model]
                )
                return nil
            }
            if SummaryCostEstimator.exceedsCloudDailyCap(
                adding: estimatedCost,
                dailyCapUSD: settings.dailyCapUSD,
                spentTodayUSD: spentToday
            ) {
                return nil
            }
        }

        let retryCount = max(settings.retryCount, 0)
        for _ in 0 ... retryCount {
            if Task.isCancelled { return nil }
            if let output = await llmClient.callOpenAICompatibleCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                timeout: settings.requestTimeoutSeconds,
                maxOutputTokens: settings.maxOutputTokens,
                includeOpenRouterHeaders: openRouterHeaders
            ), output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return output
            }
        }
        return nil
    }

    private func normalizedBase(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
