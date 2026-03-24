import XCTest
import GRDB
@testable import BurnBar

@MainActor
final class AgentLensTests: XCTestCase {

    func test_rollingDailyAverage_sevenDays() throws {
        let store = DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: Double(d),
                    startTime: day.addingTimeInterval(3600),
                    endTime: day.addingTimeInterval(7200)
                )
            )
        }
        store.replaceUsages(usages)
        let expected = (1.0 + 2.0 + 3.0 + 4.0 + 5.0 + 6.0 + 7.0) / 7.0
        XCTAssertEqual(store.rollingDailyAverage, expected, accuracy: 0.0001)
    }

    func test_rollingDailyAverage_zeroFillsMissingDays() throws {
        let store = DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in [1, 3, 5] {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: 10,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        store.replaceUsages(usages)
        XCTAssertEqual(store.rollingDailyAverage, 30.0 / 7.0, accuracy: 0.0001)
    }

    func test_moodBand_light() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 0.5, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .light)
    }

    func test_moodBand_onPace() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_moodBand_heavy() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .heavy)
    }

    func test_moodBand_baseline() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "a",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: day.addingTimeInterval(10),
            endTime: day.addingTimeInterval(20)
        )
        store.replaceUsages([u])
        XCTAssertEqual(store.moodBand, .baseline)
    }

    func test_moodBand_quiet() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 0, rollingAvg: 5))
        XCTAssertEqual(store.moodBand, .quiet)
    }

    func test_moodBand_zeroAverage() {
        let store = DataStore()
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date())
        let d1 = cal.date(byAdding: .day, value: -1, to: d0)!
        let older = TokenUsage(
            provider: .factory,
            sessionId: "old",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0,
            startTime: d1.addingTimeInterval(10),
            endTime: d1.addingTimeInterval(20)
        )
        let today = TokenUsage(
            provider: .factory,
            sessionId: "new",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 3,
            startTime: d0.addingTimeInterval(10),
            endTime: d0.addingTimeInterval(20)
        )
        store.replaceUsages([older, today])
        XCTAssertEqual(store.rollingDailyAverage, 0, accuracy: 0.0001)
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_cacheRatio_aboveThreshold() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "c",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            cacheCreationTokens: 0,
            cacheReadTokens: 25,
            costUSD: 1,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertTrue(u.totalTokens > 0)
        XCTAssertGreaterThan(Double(u.cacheReadTokens) / Double(u.totalTokens), 0.5)
    }

    func test_cacheRatio_zeroTotal() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "z",
            projectName: "p",
            model: "m",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertEqual(u.totalTokens, 0)
    }

    func test_insightCard_zeroInsights() {
        let store = DataStore()
        store.replaceUsages([])
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.isEmpty)
    }

    func test_insightCard_oneInsight() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.count >= 1)
    }

    func test_narrativeTemplate_noSessions() {
        let store = DataStore()
        store.replaceUsages([])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("No sessions"))
    }

    func test_narrativeTemplate_oneSessions() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        store.replaceUsages([u, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One ") || n.headline.contains("1"))
    }

    func test_narrativeTemplate_nSessions() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "2",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("2") || n.headline.contains("sessions"))
    }

    func test_narrativeTemplate_countsDistinctSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One "))
    }

    func test_insightCard_newSessions_countsDistinctSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])

        let insights = InsightEngine.generate(from: store)
        let newSessions = insights.first(where: { $0.type == .newSessions })
        XCTAssertEqual(newSessions?.metric, 1)
    }

    func test_narrativeTemplate_collapsesClaudeSubagentSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let topLevel = TokenUsage(
            provider: .claudeCode,
            sessionId: "root-session",
            projectName: "p",
            model: "claude-opus-4-6",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let subagent = TokenUsage(
            provider: .claudeCode,
            sessionId: "root-session/agent-abc123",
            projectName: "p",
            model: "claude-opus-4-6",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([topLevel, subagent, pastDayUsage])
        let narrative = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(narrative.headline.hasPrefix("One "))
    }

    func test_sparklineData_alwaysSevenPoints() {
        let store = DataStore()
        XCTAssertEqual(store.last7DayCosts.count, 7)
    }

    func test_modelPricing_knownModel() {
        let p = ModelPricing.lookup(model: "claude-3-5-sonnet")
        XCTAssertEqual(p.inputPerMToken, 3, accuracy: 0.001)
        XCTAssertEqual(p.outputPerMToken, 15, accuracy: 0.001)
    }

    func test_insightEngine_structuredFields() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        let insights = InsightEngine.generate(from: store)
        XCTAssertFalse(insights.isEmpty)
        let first = insights[0]
        XCTAssertFalse(first.headline.isEmpty)
        XCTAssertFalse(first.icon.isEmpty)
    }

    func test_cliBridge_parseExecutablePath_prefersAbsolutePathLine() {
        let output = """
        Loading shell config...
        /Users/tester/.nvm/versions/node/v24.14.0/bin/codex
        """

        XCTAssertEqual(
            CLIBridge.parseExecutablePath(fromCommandOutput: output),
            "/Users/tester/.nvm/versions/node/v24.14.0/bin/codex"
        )
    }

    func test_cliBridge_claudeArguments_includeVerboseForStreamJSON() {
        XCTAssertEqual(
            CLIBridge.claudeArguments(prompt: "hello"),
            ["-p", "hello", "--output-format", "stream-json", "--verbose"]
        )
    }

    func test_cliBridge_codexArguments_defaultModelAndReasoning() {
        XCTAssertEqual(
            CLIBridge.codexArguments(prompt: "hello"),
            [
                "exec",
                "--json",
                "--ephemeral",
                "--skip-git-repo-check",
                "-m",
                "gpt-5.4-mini",
                "-c",
                #"model_reasoning_effort="medium""#,
                "hello"
            ]
        )
    }

    func test_cliBridge_userManagedSearchDirectories_includeNodeManagerBins() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempHome) }

        let nvmBin = tempHome.appendingPathComponent(".nvm/versions/node/v24.14.0/bin", isDirectory: true)
        let fnmBin = tempHome.appendingPathComponent(".fnm/node-versions/v22.12.0/installation/bin", isDirectory: true)
        try fileManager.createDirectory(at: nvmBin, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: fnmBin, withIntermediateDirectories: true, attributes: nil)

        let directories = CLIBridge.userManagedExecutableSearchDirectories(
            homeDirectory: tempHome.path,
            fileManager: fileManager
        )

        XCTAssertTrue(directories.contains(nvmBin.path))
        XCTAssertTrue(directories.contains(fnmBin.path))
    }

    func test_cliBridge_resolveExecutable_findsVersionManagerInstall() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempHome) }

        let codexPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v24.14.0/bin/codex")
        try fileManager.createDirectory(
            at: codexPath.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let created = fileManager.createFile(
            atPath: codexPath.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertTrue(created)

        let directories = CLIBridge.userManagedExecutableSearchDirectories(
            homeDirectory: tempHome.path,
            fileManager: fileManager
        )

        XCTAssertEqual(
            CLIBridge.resolveExecutable(
                named: "codex",
                searchDirectories: directories,
                fileManager: fileManager
            ),
            codexPath.path
        )
    }

    func test_fileHandleReadLine_returnsNilAtEOF() throws {
        let fileManager = FileManager.default
        let tempFile = fileManager.temporaryDirectory
            .appendingPathComponent("readline-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: tempFile) }

        let created = fileManager.createFile(
            atPath: tempFile.path,
            contents: Data("first\n\nthird".utf8),
            attributes: nil
        )
        XCTAssertTrue(created)

        let handle = try FileHandle(forReadingFrom: tempFile)
        defer { try? handle.close() }

        XCTAssertEqual(handle.readLine(), "first")
        XCTAssertEqual(handle.readLine(), "")
        XCTAssertEqual(handle.readLine(), "third")
        XCTAssertNil(handle.readLine())
    }

    // MARK: - Fixtures

    private var pastDayUsage: TokenUsage {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let y = cal.date(byAdding: .day, value: -1, to: today)!
        return TokenUsage(
            provider: .factory,
            sessionId: "past",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: y.addingTimeInterval(10),
            endTime: y.addingTimeInterval(20)
        )
    }

    private func moodFixture(today: Double, rollingAvg: Double) -> [TokenUsage] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var list: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: todayStart)!
            let cost = rollingAvg
            list.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: cost,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        if today > 0 {
            list.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "today",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: today,
                    startTime: todayStart.addingTimeInterval(5000),
                    endTime: todayStart.addingTimeInterval(6000)
                )
            )
        }
        return list
    }
}

@MainActor
final class LocalSearchSchemaStoreTests: XCTestCase {

    func test_localSearchSchemaInventory_containsExpectedObjects() throws {
        let store = try makeInMemoryStore()
        let inventory = try store.localSearchSchemaInventory()

        XCTAssertEqual(
            Set(inventory.tables),
            Set([
                "chunk_embeddings",
                "embedding_models",
                "embedding_versions",
                "projection_jobs",
                "retrieval_health",
                "search_chunks",
                "search_chunks_fts",
                "search_documents"
            ])
        )
        XCTAssertEqual(
            Set(inventory.indexes),
            Set([
                "chunk_embeddings_version_lookup_idx",
                "embedding_models_provider_model_idx",
                "embedding_versions_active_idx",
                "embedding_versions_identity_idx",
                "projection_jobs_poll_idx",
                "projection_jobs_source_lookup_idx",
                "search_chunks_document_offset_idx",
                "search_chunks_source_lookup_idx",
                "search_chunks_unique_document_ordinal_idx",
                "search_documents_project_provider_idx",
                "search_documents_source_lookup_idx"
            ])
        )
    }

    func test_localSearchStore_roundTrips_document_chunk_job_embedding_and_health() throws {
        let store = try makeInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_009_600)

        let document = SearchDocumentRecord(
            id: "doc-1",
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "BurnBar",
            title: "Conversation about store split",
            subtitle: "P01",
            bodyPreview: "Schema + repository split",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-1",
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSearchDocument(document)

        let chunks = [
            SearchChunkRecord(
                id: "chunk-1",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 0,
                startOffset: 0,
                endOffset: 32,
                text: "First chunk text",
                createdAt: now,
                updatedAt: now
            ),
            SearchChunkRecord(
                id: "chunk-2",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 1,
                startOffset: 33,
                endOffset: 70,
                text: "Second chunk text",
                createdAt: now,
                updatedAt: now
            )
        ]
        try store.replaceSearchChunks(documentID: "doc-1", title: document.title, chunks: chunks)

        let fetchedDocuments = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(fetchedDocuments.count, 1)
        XCTAssertEqual(fetchedDocuments.first?.id, "doc-1")

        let fetchedChunks = try store.fetchSearchChunks(documentID: "doc-1")
        XCTAssertEqual(fetchedChunks.map(\.id), ["chunk-1", "chunk-2"])
        XCTAssertEqual(fetchedChunks.map(\.startOffset), [0, 33])
        XCTAssertEqual(fetchedChunks.map(\.endOffset), [32, 70])

        let queuedJob = ProjectionJobRecord(
            id: "job-1",
            jobType: .project,
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )
        try store.enqueueProjectionJob(queuedJob)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).count, 1)

        try store.markProjectionJobLeased(id: "job-1", leaseOwner: "worker-1", leaseDuration: 120, now: now)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.leased], limit: 10).first?.id, "job-1")
        try store.markProjectionJobCompleted(id: "job-1", completedAt: now.addingTimeInterval(60))
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.completed], limit: 10).first?.id, "job-1")

        let model = EmbeddingModelRecord(
            id: "model-1",
            provider: "openai",
            modelName: "text-embedding-3-large",
            dimensions: 3072,
            distanceMetric: .cosine,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingModel(model)
        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), ["model-1"])

        let version = EmbeddingVersionRecord(
            id: "version-1",
            modelID: "model-1",
            versionTag: "2026-03-24",
            chunkerVersion: "chunker-v1",
            normalizationVersion: "norm-v1",
            promptVersion: "prompt-v1",
            isActive: true,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingVersion(version)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: "model-1").map(\.id), ["version-1"])

        let embedding = ChunkEmbeddingRecord(
            chunkID: "chunk-1",
            embeddingVersionID: "version-1",
            vectorBlob: Data([0, 1, 2, 3]),
            createdAt: now,
            updatedAt: now
        )
        try store.upsertChunkEmbedding(embedding)
        let fetchedEmbeddings = try store.fetchChunkEmbeddings(chunkID: "chunk-1")
        XCTAssertEqual(fetchedEmbeddings.count, 1)
        XCTAssertEqual(fetchedEmbeddings.first?.vectorBlob, Data([0, 1, 2, 3]))

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTOR_TIMEOUT",
                errorMessage: "Projection worker exceeded lease",
                detailsJSON: "{\"queueDepth\":12}",
                observedAt: now,
                updatedAt: now
            )
        )
        let healthRows = try store.fetchRetrievalHealth()
        XCTAssertEqual(healthRows.count, 1)
        XCTAssertEqual(healthRows.first?.subsystem, .projection)
        XCTAssertEqual(healthRows.first?.status, .degraded)
        XCTAssertEqual(healthRows.first?.errorCode, "PROJECTOR_TIMEOUT")
    }

    func test_projectionJobs_queueOrdering_and_failureRetryState() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-ready",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-later",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base.addingTimeInterval(120),
                createdAt: base.addingTimeInterval(1),
                updatedAt: base.addingTimeInterval(1)
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-low-priority",
                jobType: .project,
                status: .queued,
                priority: 20,
                scheduledAt: base,
                availableAt: base,
                createdAt: base.addingTimeInterval(2),
                updatedAt: base.addingTimeInterval(2)
            )
        )

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queued.map(\.id), ["job-ready", "job-later", "job-low-priority"])

        let retryAt = base.addingTimeInterval(300)
        try store.markProjectionJobFailed(
            id: "job-ready",
            errorCode: "EMBEDDING_UNAVAILABLE",
            errorMessage: "Embedder offline",
            retryAt: retryAt,
            updatedAt: retryAt
        )

        let failed = try store.fetchProjectionJobs(statuses: [.failed], limit: 10)
        XCTAssertEqual(failed.count, 1)
        guard let failedJob = failed.first else {
            return XCTFail("Expected one failed job record")
        }
        XCTAssertEqual(failedJob.id, "job-ready")
        XCTAssertEqual(failedJob.attempts, 1)
        XCTAssertEqual(failedJob.lastErrorCode, "EMBEDDING_UNAVAILABLE")
        XCTAssertEqual(failedJob.availableAt.timeIntervalSince1970, retryAt.timeIntervalSince1970, accuracy: 0.001)
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
