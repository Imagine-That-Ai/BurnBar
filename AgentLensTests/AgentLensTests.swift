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
        XCTAssertEqual(
            try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["doc-1"]
        )
        XCTAssertEqual(
            try store.fetchSearchChunks(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["chunk-1", "chunk-2"]
        )

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
        XCTAssertEqual(
            try store.fetchChunkEmbeddings(embeddingVersionID: "version-1").map(\.chunkID),
            ["chunk-1"]
        )

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

@MainActor
final class SourceArtifactStoreTests: XCTestCase {
    func test_sourceArtifactStore_upsertRoundTrip_andDeleteFlow() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        let initial = SourceArtifactRecord(
            id: "artifact-1",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nInitial",
            contentHash: "hash-v1",
            fileSizeBytes: 64,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )

        XCTAssertEqual(try store.upsertSourceArtifact(initial), .inserted)

        let timestampOnlyUpdate = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: initial.body,
            contentHash: initial.contentHash,
            fileSizeBytes: initial.fileSizeBytes,
            fileModifiedAt: initial.fileModifiedAt,
            status: .active,
            discoveredAt: base.addingTimeInterval(5),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(5)
        )
        XCTAssertEqual(try store.upsertSourceArtifact(timestampOnlyUpdate), .unchanged)

        let updated = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: "# Agent Guide\nUpdated",
            contentHash: "hash-v2",
            fileSizeBytes: 72,
            fileModifiedAt: base.addingTimeInterval(10),
            status: .active,
            discoveredAt: base.addingTimeInterval(10),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(10)
        )
        XCTAssertEqual(try store.upsertSourceArtifact(updated), .updated)

        let active = try store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.contentHash, "hash-v2")

        XCTAssertTrue(try store.markSourceArtifactDeleted(id: initial.id, deletedAt: base.addingTimeInterval(20)))
        XCTAssertEqual(
            try store.fetchSourceArtifacts(includeDeleted: false, rootPaths: nil, sourceKinds: [.skillDoc, .agentDoc]).count,
            0
        )
        let allArtifacts = try store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)
    }
}

@MainActor
final class ArtifactDiscoveryServiceTests: XCTestCase {
    func test_discovery_staysWithinRegisteredRootsAndKnownPatterns() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let approvedRoot = sandbox.appendingPathComponent("approved-root", isDirectory: true)
        let outsideRoot = sandbox.appendingPathComponent("outside-root", isDirectory: true)
        try fileManager.createDirectory(at: approvedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        try writeDiscoveryFixture("# Skill\nDo this.", to: approvedRoot.appendingPathComponent("SKILL.md"))
        try writeDiscoveryFixture("# Agent\nRun tests.", to: approvedRoot.appendingPathComponent("docs/AGENTS.md"))
        try writeDiscoveryFixture("# Notes\nIgnore me.", to: approvedRoot.appendingPathComponent("README.md"))
        try writeDiscoveryFixture("# Outside\nShould not index.", to: outsideRoot.appendingPathComponent("AGENTS.md"))

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [approvedRoot.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)
        let report = try service.discoverAndIngest()

        XCTAssertEqual(report.discoveredArtifacts, 2)
        XCTAssertEqual(report.insertedArtifacts, 2)
        XCTAssertTrue(report.issues.isEmpty)

        let artifacts = try store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertFalse(artifacts.contains { $0.canonicalPath.hasPrefix(outsideRoot.path) })
        XCTAssertFalse(artifacts.contains { $0.relativePath == "README.md" })

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queuedJobs.count, 2)
        XCTAssertEqual(Set(queuedJobs.map(\.jobType)), Set([.project]))

        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .discovery })
        XCTAssertEqual(health?.status, .healthy)
    }

    func test_discovery_marksMissingArtifactsDeleted_andQueuesPurge() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        try writeDiscoveryFixture("# Agent\nv1", to: agentsURL)

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)

        _ = try service.discoverAndIngest()
        try fileManager.removeItem(at: agentsURL)
        let secondRun = try service.discoverAndIngest()

        XCTAssertEqual(secondRun.deletedArtifacts, 1)

        let allArtifacts = try store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queuedJobs.contains { $0.jobType == .purge })
    }
}

@MainActor
private final class StubArtifactDiscoverySettings: ArtifactDiscoverySettingsProviding {
    var artifactDiscoveryEnabled: Bool
    var artifactDiscoveryRegisteredRoots: [String]
    var artifactDiscoveryAdditionalKnownPatterns: [String]

    init(
        artifactDiscoveryEnabled: Bool,
        artifactDiscoveryRegisteredRoots: [String],
        artifactDiscoveryAdditionalKnownPatterns: [String] = []
    ) {
        self.artifactDiscoveryEnabled = artifactDiscoveryEnabled
        self.artifactDiscoveryRegisteredRoots = artifactDiscoveryRegisteredRoots
        self.artifactDiscoveryAdditionalKnownPatterns = artifactDiscoveryAdditionalKnownPatterns
    }
}

@MainActor
private func makeDiscoveryInMemoryStore() throws -> DataStore {
    let queue = try DatabaseQueue(path: ":memory:")
    return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
}

private func writeDiscoveryFixture(_ text: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "AgentLensTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
    }
    try data.write(to: url)
}

@MainActor
final class ProjectionPipelineServiceTests: XCTestCase {
    func test_projectionWorker_recoversExpiredRunningJob_afterCrash() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-recovery")

        let conversation = makeConversation(
            id: "conv-crash",
            fullText: "Line 1\nLine 2\nLine 3",
            indexedAt: Date(timeIntervalSince1970: 1_742_200_000)
        )
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let expiredLeaseTime = Date(timeIntervalSince1970: 1_742_200_010)
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: .project,
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID
                ),
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .running,
                priority: 5,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: expiredLeaseTime,
                availableAt: expiredLeaseTime,
                startedAt: expiredLeaseTime,
                leaseOwner: "stale-worker",
                leaseExpiresAt: expiredLeaseTime.addingTimeInterval(-30),
                createdAt: expiredLeaseTime,
                updatedAt: expiredLeaseTime
            )
        )

        let report = try service.runSweep(maxJobs: 5)
        XCTAssertGreaterThanOrEqual(report.completedJobs, 1)

        let completed = try store.fetchProjectionJobs(statuses: [.completed], limit: 20)
        XCTAssertTrue(completed.contains(where: { $0.sourceID == conversation.id }))

        let documents = try store.fetchSearchDocuments(limit: 20)
        guard let projectedConversationDocument = documents.first(where: { $0.sourceID == conversation.id }) else {
            return XCTFail("Expected projected document for crash-recovered conversation.")
        }
        let chunks = try store.fetchSearchChunks(documentID: projectedConversationDocument.id)
        XCTAssertFalse(chunks.isEmpty)
    }

    func test_projectionJob_enqueueSuppression_preventsDuplicateRequeueAfterCompletion() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-duplicates")
        let now = Date(timeIntervalSince1970: 1_742_300_000)

        let conversation = makeConversation(id: "conv-dedupe", fullText: String(repeating: "abc ", count: 500), indexedAt: now)
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let job = ProjectionJobRecord(
            id: ProjectionIdentity.jobID(
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID
            ),
            jobType: .project,
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: sourceVersionID,
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )

        try store.enqueueProjectionJob(job)
        try store.enqueueProjectionJob(job)
        _ = try service.runSweep(maxJobs: 10)

        let documents = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(documents.count, 1)
        let chunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertGreaterThan(chunkCount, 1)

        try store.enqueueProjectionJob(job)
        XCTAssertTrue(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).isEmpty)

        let secondSweep = try service.runSweep(maxJobs: 10)
        XCTAssertEqual(secondSweep.completedJobs, 0)
        let secondChunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertEqual(secondChunkCount, chunkCount)
    }

    func test_projectionPipeline_handlesArtifactDeleteWithPurgeJob() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-purge")
        let base = Date(timeIntervalSince1970: 1_742_400_000)

        let artifact = SourceArtifactRecord(
            id: "artifact-delete",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/project/AGENTS.md",
            rootPath: "/tmp/project",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nRun tests first.",
            contentHash: "hash-delete-v1",
            fileSizeBytes: 42,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try service.runSweep(maxJobs: 10)
        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 1)

        XCTAssertTrue(try store.markSourceArtifactDeleted(id: artifact.id, deletedAt: base.addingTimeInterval(60)))
        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
            jobType: .purge,
            priority: 2
        )
        _ = try service.runSweep(maxJobs: 10)

        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 0)
    }

    func test_rebuildJob_enqueuesReprojectAndPurgeCandidates() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-rebuild")
        let base = Date(timeIntervalSince1970: 1_742_500_000)

        let conversation = makeConversation(id: "conv-rebuild", fullText: "Need to rebuild projections.", indexedAt: base)
        try store.upsertConversation(conversation)

        let activeArtifact = SourceArtifactRecord(
            id: "artifact-active",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/repo/SKILL.md",
            rootPath: "/tmp/repo",
            relativePath: "SKILL.md",
            provenance: "basename:SKILL.MD",
            title: "Skill",
            body: "# Skill\nDo this.",
            contentHash: "hash-active",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(activeArtifact)

        let deletedArtifact = SourceArtifactRecord(
            id: "artifact-deleted",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agents",
            body: "# Agents\nLegacy",
            contentHash: "hash-deleted",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(deletedArtifact)
        XCTAssertTrue(try store.markSourceArtifactDeleted(id: deletedArtifact.id, deletedAt: base.addingTimeInterval(120)))

        try service.enqueueRebuildJob(reason: "test-rebuild", priority: 1)
        let rebuildReport = try service.runSweep(maxJobs: 1)
        XCTAssertEqual(rebuildReport.completedJobs, 1)

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == .conversation && $0.sourceID == conversation.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == activeArtifact.sourceKind && $0.sourceID == activeArtifact.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == deletedArtifact.sourceKind && $0.sourceID == deletedArtifact.id && $0.jobType == .purge }))
    }

    func test_projectionPipeline_indexesEmbeddings_withActiveVersionLineage() throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-v1")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embedding-lineage",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_510_000)

        let conversation = makeConversation(
            id: "conv-embedding-lineage",
            fullText: "Embedding lineage test for hybrid retrieval indexing.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try service.runSweep(maxJobs: 20)

        let expectedModelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let expectedVersionID = EmbeddingIdentity.versionID(for: embedder.descriptor)

        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), [expectedModelID])
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.id, expectedVersionID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.isActive, true)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id })
        else {
            return XCTFail("Expected projected conversation document for embedding lineage test.")
        }
        let chunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty)

        let indexedEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: expectedVersionID)
        XCTAssertEqual(Set(indexedEmbeddings.map(\.chunkID)), Set(chunks.map(\.id)))
        if let firstVector = indexedEmbeddings.first?.vectorBlob, let decoded = VectorBlobCodec.decode(firstVector) {
            XCTAssertEqual(decoded.count, embedder.descriptor.dimensions)
        } else {
            XCTFail("Expected a decodable embedding vector.")
        }
    }

    func test_reembedJob_createsNewActiveEmbeddingVersion_withoutRemovingPreviousVersion() throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedderV1 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-a")
        let serviceV1 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v1",
            chunkEmbedder: embedderV1
        )
        let base = Date(timeIntervalSince1970: 1_742_520_000)
        let conversation = makeConversation(
            id: "conv-reembed",
            fullText: "Re-embed this conversation into the new embedding version.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try serviceV1.runSweep(maxJobs: 20)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id }),
            let chunk = try store.fetchSearchChunks(documentID: document.id).first
        else {
            return XCTFail("Expected projected chunk before re-embed.")
        }

        let versionV1ID = EmbeddingIdentity.versionID(for: embedderV1.descriptor)
        guard
            let blobV1 = try store.fetchChunkEmbeddings(chunkID: chunk.id).first(where: { $0.embeddingVersionID == versionV1ID })?.vectorBlob
        else {
            return XCTFail("Expected initial embedding for first version.")
        }

        let embedderV2 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v2", seed: "projection-seed-b")
        let serviceV2 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v2",
            chunkEmbedder: embedderV2
        )
        try serviceV2.enqueueReembedJob(
            reason: "test-reembed",
            sourceKind: .conversation,
            sourceID: conversation.id,
            priority: 1
        )
        _ = try serviceV2.runSweep(maxJobs: 20)

        let versionV2ID = EmbeddingIdentity.versionID(for: embedderV2.descriptor)
        let chunkEmbeddings = try store.fetchChunkEmbeddings(chunkID: chunk.id)
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV1ID })
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV2ID })
        XCTAssertNotEqual(
            chunkEmbeddings.first(where: { $0.embeddingVersionID == versionV2ID })?.vectorBlob,
            blobV1
        )

        let modelID = EmbeddingIdentity.modelID(for: embedderV2.descriptor)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.id, versionV2ID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.isActive, true)
    }

    func test_timestampNormalization_convertsMillisecondEpochToSeconds() {
        let milliseconds = 1_774_329_122_146.0
        let normalized = TimestampNormalizationUtility.normalizedEpochSeconds(milliseconds)

        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized ?? 0, milliseconds / 1000.0, accuracy: 0.0001)
    }

    func test_timestampNormalization_firestoreSafeDateRepairsMillisecondAsSecondDate() {
        let invalidDate = Date(timeIntervalSince1970: 1_774_329_122_146.0)
        let safeDate = TimestampNormalizationUtility.firestoreSafeDate(invalidDate)

        XCTAssertEqual(safeDate.timeIntervalSince1970, 1_774_329_122.146, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            safeDate.timeIntervalSince1970,
            TimestampNormalizationUtility.firestoreMaxEpochSeconds
        )
    }

    private func makeConversation(id: String, fullText: String, indexedAt: Date) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "BurnBar",
            startTime: indexedAt.addingTimeInterval(-60),
            endTime: indexedAt,
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: ["DataStore.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: "Projection Test",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }
}

final class ProjectionChunkerTests: XCTestCase {
    func test_chunker_isDeterministicForSameInput() {
        let text = """
        # Title
        Intro paragraph.

        ## Section A
        \(String(repeating: "Alpha beta gamma. ", count: 120))

        ## Section B
        \(String(repeating: "Delta epsilon zeta. ", count: 120))
        """

        let chunker = ProjectionChunker(maxChunkCharacters: 280, minChunkCharacters: 160, overlapCharacters: 40, maxChunksPerDocument: 32)
        let createdAt = Date(timeIntervalSince1970: 1_742_600_000)
        let first = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )
        let second = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )

        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.startOffset), second.map(\.startOffset))
        XCTAssertEqual(first.map(\.endOffset), second.map(\.endOffset))
        XCTAssertEqual(first.map(\.sectionPath), second.map(\.sectionPath))
        XCTAssertEqual(first.map(\.text), second.map(\.text))
    }
}

@MainActor
private final class StubSemanticCandidateProvider: SemanticCandidateProviding {
    enum StubError: Error {
        case forced
    }

    var responses: [String: [SemanticCandidate]]
    var shouldThrow = false

    init(responses: [String: [SemanticCandidate]] = [:]) {
        self.responses = responses
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        if shouldThrow {
            throw StubError.forced
        }
        return Array((responses[query] ?? []).prefix(max(0, limit)))
    }
}

@MainActor
final class HybridRetrievalServiceTests: XCTestCase {
    func test_retrieval_lexicalWinsAgainstSemanticOnlyCandidate() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-lexical-wins")
        let base = Date(timeIntervalSince1970: 1_742_700_000)

        let lexicalConversation = makeConversation(
            id: "conv-lexical",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Discussion about quartzwind rollout and release hardening.",
            indexedAt: base.addingTimeInterval(-120),
            sourceType: .providerLog
        )
        let semanticConversation = makeConversation(
            id: "conv-semantic",
            provider: .codex,
            projectName: "Beta",
            fullText: "This thread focuses on runtime migration and queue tuning.",
            indexedAt: base.addingTimeInterval(-60),
            sourceType: .providerLog
        )

        try store.upsertConversation(lexicalConversation)
        try store.upsertConversation(semanticConversation)
        try store.enqueueConversationProjectionJob(conversationID: lexicalConversation.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: semanticConversation.id, jobType: .project, now: base)
        _ = try projector.runSweep(maxJobs: 20)

        guard
            let semanticDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == semanticConversation.id }),
            let semanticChunk = try store.fetchSearchChunks(documentID: semanticDoc.id).first
        else {
            return XCTFail("Expected projected semantic conversation chunk.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "quartzwind": [SemanticCandidate(chunkID: semanticChunk.id, score: 0.99)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "quartzwind",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.sourceID, lexicalConversation.id)
        XCTAssertEqual(results.first?.sourceKind, .conversation)
    }

    func test_retrieval_semanticRescueReturnsResultWhenLexicalIsEmpty() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-semantic-rescue")
        let base = Date(timeIntervalSince1970: 1_742_710_000)

        let artifact = makeArtifact(
            id: "artifact-semantic-rescue",
            sourceKind: .skillDoc,
            rootPath: "/tmp/alpha-repo",
            relativePath: "SKILL.md",
            title: "Bootstrap skill",
            body: "Workstation bootstrap checklist for new machine setup.",
            contentHash: "hash-semantic-rescue",
            fileModifiedAt: base
        )

        _ = try store.upsertSourceArtifact(artifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try projector.runSweep(maxJobs: 10)

        guard
            let artifactDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == artifact.id }),
            let artifactChunk = try store.fetchSearchChunks(documentID: artifactDoc.id).first
        else {
            return XCTFail("Expected projected artifact chunk for semantic rescue.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "onboarding runbook": [SemanticCandidate(chunkID: artifactChunk.id, score: 0.92)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "onboarding runbook",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, artifact.id)
        XCTAssertEqual(results.first?.sourceKind, .skillDoc)
        XCTAssertNotNil(results.first?.semanticScore)
        XCTAssertNil(results.first?.lexicalRank)
    }

    func test_retrieval_emptyQueryReturnsNoResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let retrieval = SearchService(dataStore: store)

        let results = await retrieval.retrieve(RetrievalQuery(text: "   \n\t  "))
        XCTAssertTrue(results.isEmpty)
    }

    func test_retrieval_filters_applyProviderProjectArtifactDateOwnershipAndSource() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-filters")
        let base = Date(timeIntervalSince1970: 1_742_720_000)

        let convClaude = makeConversation(
            id: "conv-claude-alpha",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-86_400),
            sourceType: .providerLog
        )
        let convCodex = makeConversation(
            id: "conv-codex-beta",
            provider: .codex,
            projectName: "Beta",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-40 * 86_400),
            sourceType: .providerLog
        )
        let convCLI = makeConversation(
            id: "conv-cli-alpha",
            provider: .factory,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-2 * 86_400),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(convClaude)
        try store.upsertConversation(convCodex)
        try store.upsertConversation(convCLI)
        try store.enqueueConversationProjectionJob(conversationID: convClaude.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCodex.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCLI.id, jobType: .project, now: base)

        let skillArtifact = makeArtifact(
            id: "artifact-skill-alpha",
            sourceKind: .skillDoc,
            rootPath: "/tmp/AlphaRepo",
            relativePath: "SKILL.md",
            title: "Skill Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-skill-alpha",
            fileModifiedAt: base.addingTimeInterval(-3 * 86_400)
        )
        let sharedArtifact = makeArtifact(
            id: "artifact-shared-alpha",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/SharedRepo",
            relativePath: "SHARED.md",
            title: "Shared Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-shared-alpha",
            fileModifiedAt: base.addingTimeInterval(-4 * 86_400)
        )

        _ = try store.upsertSourceArtifact(skillArtifact)
        _ = try store.upsertSourceArtifact(sharedArtifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: skillArtifact.sourceKind,
            sourceID: skillArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: skillArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        try projector.enqueueSelectiveReproject(
            sourceKind: sharedArtifact.sourceKind,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )

        _ = try projector.runSweep(maxJobs: 40)

        let retrieval = SearchService(dataStore: store, nowProvider: { base })

        let providerFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(providerFiltered.map(\.sourceID)), Set([convClaude.id]))

        let projectFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(projectName: "Alpha", artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(projectFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let artifactTypeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(artifactTypeFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let recentConversationRange = base.addingTimeInterval(-7 * 86_400)...base
        let dateFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: recentConversationRange),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(dateFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let sharedOnly = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sharedOnly.map(\.sourceID)), Set([sharedArtifact.id]))
        XCTAssertTrue(sharedOnly.allSatisfy { $0.sourceKind == .sharedArtifact })

        let sourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(sourceIDs: [skillArtifact.id]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sourceFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let conversationSourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    conversationSources: [.cliAssistant]
                ),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(conversationSourceFiltered.map(\.sourceID)), Set([convCLI.id]))
        XCTAssertTrue(conversationSourceFiltered.allSatisfy { $0.conversation?.sourceType == .cliAssistant })
    }

    func test_vectorSemanticCandidates_annAndExactMatch_whenExactRerankEnabled() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_730_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "ann-parity-v1",
            seed: "ann-parity-seed-v1"
        )

        let modelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        try store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: embedder.descriptor.provider,
                modelName: embedder.descriptor.modelName,
                dimensions: embedder.descriptor.dimensions,
                distanceMetric: embedder.descriptor.distanceMetric,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: versionID,
                modelID: modelID,
                versionTag: embedder.descriptor.versionTag,
                chunkerVersion: embedder.descriptor.chunkerVersion,
                normalizationVersion: embedder.descriptor.normalizationVersion,
                promptVersion: embedder.descriptor.promptVersion,
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        for index in 0..<96 {
            let docID = "doc-ann-\(index)"
            let sourceID = "artifact-ann-\(index)"
            let title = "ANN Candidate Document \(index)"
            let chunkText: String
            if index % 13 == 0 {
                chunkText = "reliability hardening checklist rollout runbook \(index)"
            } else {
                chunkText = "generic notes \(index) queue metrics stabilization tracking"
            }

            let document = SearchDocumentRecord(
                id: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                provider: nil,
                projectName: "VectorParity",
                title: title,
                subtitle: "SKILL.md",
                bodyPreview: String(chunkText.prefix(120)),
                sourceUpdatedAt: base,
                indexedAt: base,
                contentHash: "hash-\(index)",
                createdAt: base,
                updatedAt: base
            )
            try store.upsertSearchDocument(document)

            let chunk = SearchChunkRecord(
                id: "chunk-ann-\(index)",
                documentID: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                ordinal: 0,
                startOffset: 0,
                endOffset: chunkText.utf16.count,
                messageStartOffset: nil,
                messageEndOffset: nil,
                sectionPath: nil,
                text: chunkText,
                createdAt: base,
                updatedAt: base
            )
            try store.replaceSearchChunks(documentID: docID, title: title, chunks: [chunk])

            let vector = try embedder.embedding(for: chunkText)
            try store.upsertChunkEmbedding(
                ChunkEmbeddingRecord(
                    chunkID: chunk.id,
                    embeddingVersionID: versionID,
                    vectorBlob: VectorBlobCodec.encode(vector),
                    createdAt: base,
                    updatedAt: base
                )
            )
        }

        let queryEmbedder = DeterministicQueryEmbeddingProvider(embedder: embedder)
        let annProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            annCandidateMultiplier: 32,
            nowProvider: { base }
        )
        let exactProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .exact,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { base }
        )

        let query = "reliability hardening checklist rollout"
        let annCandidates = try await annProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)
        let exactCandidates = try await exactProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        XCTAssertEqual(annCandidates.map(\.chunkID), exactCandidates.map(\.chunkID))
        XCTAssertEqual(annCandidates.count, exactCandidates.count)
        if let annTop = annCandidates.first?.score, let exactTop = exactCandidates.first?.score {
            XCTAssertEqual(annTop, exactTop, accuracy: 0.000001)
        }
    }

    private func makeConversation(
        id: String,
        provider: AgentProvider,
        projectName: String,
        fullText: String,
        indexedAt: Date,
        sourceType: ConversationSourceType
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: "session-\(id)",
            projectName: projectName,
            startTime: indexedAt.addingTimeInterval(-120),
            endTime: indexedAt,
            messageCount: 6,
            userWordCount: 48,
            assistantWordCount: 76,
            keyFiles: ["SearchService.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Retrieval Test \(id)",
            lastAssistantMessage: "Done",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: sourceType
        )
    }

    private func makeArtifact(
        id: String,
        sourceKind: SearchSourceKind,
        rootPath: String,
        relativePath: String,
        title: String,
        body: String,
        contentHash: String,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: "\(rootPath)/\(relativePath)",
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: "test:\(relativePath)",
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: fileModifiedAt,
            status: .active,
            discoveredAt: fileModifiedAt,
            deletedAt: nil,
            createdAt: fileModifiedAt,
            updatedAt: fileModifiedAt
        )
    }
}
