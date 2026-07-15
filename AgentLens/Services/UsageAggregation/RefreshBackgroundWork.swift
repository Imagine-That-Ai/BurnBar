import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Refresh Result Types

/// Value type returned by the off-main refresh work.  Carries all the data
/// the `@MainActor UsageAggregator` needs to update its observable state in
/// one atomic step — no incremental main-actor mutations during the heavy work.
struct FullRefreshResult: Sendable {
    var parserHealth: [AgentProvider: ParserHealth] = [:]
    var errors: [AgentProvider: String] = [:]
    var allUsages: [TokenUsage] = []
    var persistenceErrorMessage: String?
    var typedPersistenceError: OpenBurnBarError?
    var healthWriteError: String?
    var parsePhaseDuration: TimeInterval = 0
    var persistencePhaseDuration: TimeInterval = 0
    var indexedConversationChanges: Int = 0
    var postPersistence: PostPersistenceResult
}

struct SingleProviderResult: Sendable {
    var usages: [TokenUsage] = []
    var conversations: [OpenBurnBarCore.ConversationRecord] = []
    var health: ParserHealth = .empty
    var indexedConversationChanges: Int = 0
    var error: String?
}

struct ConversationIndexingResult: Sendable {
    var indexedConversationChanges: Int = 0
    /// Total conversations returned by parsers (cached + fresh).
    var parsedConversationCount: Int = 0
    /// Conversations that passed the changed-signature filter and were
    /// submitted to the indexer. At steady state this is 0.
    var changedConversationCount: Int = 0
    var errors: [AgentProvider: String] = [:]
    var duration: TimeInterval = 0
}

// MARK: - Refresh Background Work

/// Stateless namespace for off-main-thread refresh work.
///
/// `UsageAggregator` snapshots any `@MainActor` state it needs (settings,
/// API configs) *before* calling into these functions. Because the namespace is
/// `nonisolated`, awaiting these `async` functions from the main actor runs them
/// off it (SE-0338); they return value types that the aggregator applies back on
/// `@MainActor` in one step.
enum RefreshBackgroundWork {

    // MARK: - Full Refresh

    /// Runs the full parse → persist → post-persistence pipeline off the
    /// main thread.  `await` it from the main actor; being `nonisolated` it runs
    /// off the main actor (SE-0338).
    static func runFullRefresh(
        parsers: [AgentProvider: any OpenBurnBarCore.LogParser],
        dataStore: DataStore,
        orchestrator: RefreshOrchestrator,
        existingUsages: [TokenUsage],
        settings: RefreshSettingsSnapshot
    ) async throws -> FullRefreshResult {
        var result = FullRefreshResult(
            postPersistence: PostPersistenceResult()
        )

        let pipeline = UsageRefreshPipeline(
            parsers: parsers,
            dataStore: dataStore,
            orchestrator: orchestrator,
            existingUsages: existingUsages,
            settings: settings
        )

        // discover → usage-only parse → persist
        //
        // Conversation bodies are intentionally excluded here. The caller
        // schedules the optional indexing pass after this result is applied so
        // today's token usage is visible without waiting for historical text
        // reconstruction.
        let discovery = pipeline.discover()
        let parsed = try await pipeline.parse(
            from: discovery,
            includeConversationBodies: false
        )
        let reconciled = await pipeline.reconcile(parsed: parsed)
        let persisted = await pipeline.persist(parsed: parsed)

        result.parserHealth = parsed.parserHealth
        result.errors = parsed.errors
        result.allUsages = parsed.allUsages
        result.parsePhaseDuration = parsed.duration
        result.indexedConversationChanges = reconciled.indexedConversationChanges
        result.persistenceErrorMessage = persisted.persistenceErrorMessage
        result.typedPersistenceError = persisted.typedPersistenceError
        result.persistencePhaseDuration = persisted.duration

        do {
            try await pipeline.writeParserHealth(parsed: parsed, persist: persisted)
        } catch {
            result.healthWriteError = "Failed to persist parser/import health: \(error.localizedDescription)"
        }

        // ── Backfill ─────────────────────────────────────────────────
        if result.persistenceErrorMessage == nil {
            await orchestrator.runScheduledBackfillIfNeeded(parsers: parsers)
        }

        // ── Post-Persistence Phase (API reconcile + quota) ───────────
        result.postPersistence = await orchestrator.runPostPersistencePhaseOffMain(
            allUsages: parsed.allUsages,
            snapshotAPIs: settings.snapshotAPIs
        )

        return result
    }

    // MARK: - Optional Conversation Indexing

    /// Re-parses providers with conversation bodies enabled and indexes those
    /// records after the usage-only refresh has already published its rows.
    ///
    /// P-PERF-2: incremental indexing via checkpoint high-watermark.
    ///
    /// Each provider's `parser_checkpoints` row stores a scan-start watermark
    /// — the wall-clock time at the **beginning** of the last successful
    /// indexing pass. On each tick:
    ///
    /// 1. **Capture scan-start watermark** (`Date()` at the start of this
    ///    provider's processing, BEFORE parsing). This is the safe boundary:
    ///    any file modified at or before this moment was visible to this scan
    ///    and will be indexed. Files modified after this moment are genuine
    ///    new changes that the next tick will see.
    /// 2. The parser runs (it already skips re-reading unchanged files via
    ///    `CompositeFileSignature` cache hits — only file stat calls, no
    ///    content reads, for unchanged files).
    /// 3. Conversations whose `fileModifiedAt` is ≤ the **previous** checkpoint
    ///    watermark AND whose ID already exists in the database are filtered
    ///    out before reaching the indexer — no DB fetch, no upsert, no
    ///    projection job enqueue. This is the sub-linear gate.
    ///    Newly discovered sessions (ID not in DB) are always passed through
    ///    regardless of file mtime — they were never indexed.
    /// 4. The remaining (changed/appended/new) conversations are **all**
    ///    processed — no cap, no deferred drops. `ConversationIndexer.index`
    ///    handles the full changed set using chunked batch DB fetches
    ///    (O(ceil(N/500)) queries, not O(N) roundtrips).
    /// 5. After successful indexing, the checkpoint watermark advances to the
    ///    **scan-start** watermark (step 1), NOT `Date()` after processing.
    ///    This ensures files created during the scan (between scan-start and
    ///    checkpoint-advance) are seen on the next tick — their
    ///    `fileModifiedAt > scanStartWatermark`. Harmless bounded reprocessing
    ///    is preferable to loss. If indexing throws, the checkpoint is NOT
    ///    advanced — the next tick retries against the same watermark.
    ///
    /// At steady state (no file changes): step 3 filters out 100% of records,
    /// the indexer receives an empty array, and the only work is the parser's
    /// file-stat loop + one checkpoint read per provider — explicitly bounded,
    /// not O(corpus) DB operations.
    static func runConversationIndexing(
        parsers: [AgentProvider: any OpenBurnBarCore.LogParser],
        dataStore: DataStore,
        orchestrator: RefreshOrchestrator,
        indexingEnabled: Bool
    ) async -> ConversationIndexingResult {
        var result = ConversationIndexingResult()
        let startedAt = Date()
        let parserEntries = parsers.sorted { $0.key.rawValue < $1.key.rawValue }
        let checkpointStore = dataStore.checkpointStore

        for (provider, parser) in parserEntries {
            do {
                // P-PERF-2: capture scan-start watermark BEFORE parsing.
                // This is the safe boundary that will be written to the
                // checkpoint after successful indexing. Using scan-start
                // (not post-processing Date()) ensures files created during
                // the scan are seen on the next tick (review finding 5).
                let scanStartWatermark = Date()

                let parseResult = try await parser.parse(
                    options: OpenBurnBarCore.LogParseOptions(includeConversationBodies: indexingEnabled)
                )
                result.parsedConversationCount += parseResult.conversations.count

                guard indexingEnabled else { continue }

                // Fetch the PREVIOUS checkpoint watermark (from the last
                // successful indexing pass). nil = first run or corrupted →
                // process all (safe recovery, VAL-PERSIST-014).
                let existingCheckpoint = try? await checkpointStore.fetchCheckpoint(for: provider)
                let previousWatermark: Date? = existingCheckpoint?.lastProcessedAt

                // Filter to changed/appended conversations and newly
                // discovered sessions.
                //
                // Review finding 2: a transcript discovered after the
                // checkpoint but with an older fileModifiedAt (restored
                // archive, copied directory, parser starts watching an older
                // path) would be silently dropped by a mtime-only filter. We
                // also pass through any conversation whose ID is NOT yet in
                // the database — those are genuine new sessions that must be
                // indexed regardless of file mtime.
                let allConversations = parseResult.conversations
                let existingIDs: Set<String> = (try? await dataStore.fetchExistingConversationIDs(
                    ids: allConversations.map(\.id)
                )) ?? []

                let changedConversations: [OpenBurnBarCore.ConversationRecord]
                if let previousWatermark {
                    changedConversations = allConversations.filter { convo in
                        // New session: not in DB → always index (finding 2).
                        if !existingIDs.contains(convo.id) { return true }
                        // fileModifiedAt nil → can't determine → always index.
                        guard let mtime = convo.fileModifiedAt else { return true }
                        // Changed since last successful index.
                        return mtime > previousWatermark
                    }
                } else {
                    changedConversations = allConversations
                }

                result.changedConversationCount += changedConversations.count

                guard !changedConversations.isEmpty else {
                    // No changed conversations — advance the checkpoint to
                    // scan-start so the next tick uses the updated watermark.
                    // This ensures files created during this scan (even
                    // though no changed conversations were returned by the
                    // parser) are seen on the next tick.
                    let token = "idx:\(scanStartWatermark.timeIntervalSince1970)"
                    try? await checkpointStore.advanceCheckpoint(
                        for: provider,
                        checkpointToken: token,
                        lastProcessedFilePath: nil
                    )
                    continue
                }

                // Process the FULL changed set — no cap, no deferred drops.
                // ConversationIndexer.index chunks the batch DB fetch
                // internally (500 IDs per query) to stay under SQLite's
                // SQLITE_MAX_VARIABLE_NUMBER limit (review finding 4).
                //
                // Review finding 3: use the throwing variant so a failed
                // indexing pass does NOT advance the checkpoint — the next
                // tick retries the failed upserts instead of filtering them
                // out by watermark.
                do {
                    let indexingReport = try await orchestrator.indexConversationsOffMainThrowing(
                        changedConversations,
                        indexingEnabled: indexingEnabled
                    )
                    result.indexedConversationChanges += indexingReport.changedRecordCount
                } catch {
                    // Indexing failed — do NOT advance the checkpoint.
                    // The next tick re-evaluates these conversations against
                    // the SAME (old) watermark and retries.
                    result.errors[provider] = error.localizedDescription
                    continue
                }

                // Advance checkpoint watermark to scan-start after successful
                // indexing.
                // VAL-PERSIST-004: checkpoint advances only after successful commit.
                // Using scan-start (not post-processing Date()) ensures
                // files created during the scan are seen on the next tick
                // (review finding 5). Harmless bounded reprocessing is
                // preferable to loss.
                let token = "idx:\(scanStartWatermark.timeIntervalSince1970)"
                try? await checkpointStore.advanceCheckpoint(
                    for: provider,
                    checkpointToken: token,
                    lastProcessedFilePath: nil
                )
            } catch is CancellationError {
                return result
            } catch {
                result.errors[provider] = error.localizedDescription
            }
        }

        result.duration = Date().timeIntervalSince(startedAt)

        // P-PERF-2: visible cost logging — no silent truncation.
        // At steady state: parsed_count > 0, changed_count = 0,
        // indexed_changes = 0. This proves the checkpoint watermark filters
        // out the full unchanged corpus before it reaches the indexer.
        AppLogger.parser.info(
            "conversation_indexing_timing",
            metadata: [
                "parsed_count": String(result.parsedConversationCount),
                "changed_count": String(result.changedConversationCount),
                "indexed_changes": String(result.indexedConversationChanges),
                "duration_ms": String(format: "%.2f", result.duration * 1_000),
                "providers_scanned": String(parserEntries.count)
            ]
        )

        return result
    }

    // MARK: - Single Provider Refresh

    static func runSingleProviderRefresh(
        provider: AgentProvider,
        parser: any OpenBurnBarCore.LogParser,
        dataStore: DataStore,
        settings: RefreshSettingsSnapshot
    ) async -> SingleProviderResult {
        var result = SingleProviderResult()

        do {
            let parseResult = try await parser.parse(
                options: OpenBurnBarCore.LogParseOptions(includeConversationBodies: false)
            )
            result.usages = parseResult.usages
            result.health = parseResult.usages.isEmpty
                ? .empty
                : .healthy(sessionCount: parseResult.usages.count)

            try await dataStore.insertChunked(parseResult.usages, chunkSize: 500)
        } catch {
            result.health = .failed(error: error.localizedDescription)
            result.error = "Provider refresh failed for \(provider.displayName): \(error.localizedDescription)"
        }

        return result
    }

    // MARK: - Health Persistence

    /// Writes a `RetrievalHealthRecord` summarising parser import status.
    /// All DB access goes through `nonisolated` `DataStore` extensions,
    /// so this is safe to call from any executor.
    static func writeParserImportHealth(
        parserHealth: [AgentProvider: ParserHealth],
        parsers: [AgentProvider: any OpenBurnBarCore.LogParser],
        dataStore: DataStore,
        importedUsageCount: Int,
        persistenceError: String?,
        conversationIndexingEnabled: Bool
    ) async throws {
        let providers = parsers.keys.sorted { $0.rawValue < $1.rawValue }
        let providerStates = providers.map { provider -> ParserImportHealthProviderState in
            let health = parserHealth[provider] ?? .notConfigured
            return ParserImportHealthProviderState(
                provider: provider.rawValue,
                status: health.statusLabel,
                sessionCount: health.sessionCount,
                errorMessage: health.errorMessage
            )
        }

        let healthyCount = providerStates.filter { $0.status == "healthy" }.count
        let emptyCount = providerStates.filter { $0.status == "empty" }.count
        let degradedCount = providerStates.filter { $0.status == "degraded" }.count
        let failedCount = providerStates.filter { $0.status == "failed" }.count

        let status: RetrievalHealthStatus
        let errorCode: String?
        let errorMessage: String?

        if let persistenceError, !persistenceError.isEmpty {
            status = .failed
            errorCode = "PARSER_IMPORT_PERSISTENCE_FAILED"
            errorMessage = persistenceError
        } else if failedCount > 0, failedCount == providerStates.count {
            status = .failed
            errorCode = "PARSER_IMPORT_ALL_PROVIDERS_FAILED"
            errorMessage = "All parser imports failed during the latest refresh."
        } else if failedCount > 0 || degradedCount > 0 {
            status = .degraded
            errorCode = "PARSER_IMPORT_PARTIAL_FAILURE"
            errorMessage = "Parser import completed with partial failures."
        } else {
            status = .healthy
            errorCode = nil
            errorMessage = nil
        }

        let details = ParserImportHealthDetails(
            scannedProviders: providerStates.count,
            importedUsageCount: max(0, importedUsageCount),
            healthyProviders: healthyCount,
            emptyProviders: emptyCount,
            degradedProviders: degradedCount,
            failedProviders: failedCount,
            conversationIndexingEnabled: conversationIndexingEnabled,
            providerStates: providerStates
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)

        // Same change-gate as InsightEngine.upsertHealthIfChanged: at idle this
        // row is byte-identical every tick, and rewriting it took the
        // single-writer queue for nothing.
        let existing = try await dataStore.fetchRetrievalHealth()
            .first(where: { $0.subsystem == .parserImport })
        if let existing,
           existing.status == status,
           existing.detailsJSON == detailsJSON,
           existing.errorCode == errorCode,
           existing.errorMessage == errorMessage {
            return
        }

        let now = Date()
        try await dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .parserImport,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }
}

// MARK: - Settings Snapshot

/// A `Sendable` snapshot of all settings and pre-built API instances needed
/// by `RefreshBackgroundWork`.  Built on `@MainActor` *before* entering the
/// background context so no main-actor hops are required during heavy work.
struct RefreshSettingsSnapshot: Sendable {
    var conversationIndexingEnabled: Bool
    var snapshotAPIs: [any ProviderUsageAPI]
}