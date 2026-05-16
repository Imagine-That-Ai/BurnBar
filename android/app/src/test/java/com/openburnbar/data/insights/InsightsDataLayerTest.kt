package com.openburnbar.data.insights

import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.insights.services.InMemoryInsightDataSource
import com.openburnbar.data.insights.services.InsightAggregator
import com.openburnbar.data.insights.services.adapters.LocalRuleBasedAdapter
import com.openburnbar.data.insights.services.InsightExecutor
import com.openburnbar.data.insights.services.RuleBasedInsightAnalysisEngine
import com.openburnbar.ui.insights.MissionRuntimeTarget
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class InsightsDataLayerTest {

    private val testDigest = runBlocking {
        InMemoryInsightDataSource().buildDigest(InsightFilter())
    }

    @Test
    fun `placeNew positions widgets sequentially`() {
        val layout = InsightLayout()
        val placed = layout.placeNew("w1", 3 to 2)
        assertEquals(0, placed.placements["w1"]?.column)
        assertEquals(0, placed.placements["w1"]?.row)
        assertEquals(3, placed.placements["w1"]?.colSpan)
        assertEquals(2, placed.placements["w1"]?.rowSpan)
    }

    @Test
    fun `placeNew stacks widgets when row is full`() {
        var layout = InsightLayout(columnCount = 4)
        layout = layout.placeNew("w1", 3 to 1)
        layout = layout.placeNew("w2", 3 to 1)
        assertEquals(0, layout.placements["w1"]?.column)
    }

    @Test
    fun `move repositions a widget`() {
        var layout = InsightLayout(columnCount = 12)
        layout = layout.placeNew("w1", 4 to 2)
        layout = layout.move("w1", toColumn = 6, toRow = 3)
        assertEquals(6, layout.placements["w1"]?.column)
        assertEquals(3, layout.placements["w1"]?.row)
    }

    @Test
    fun `remove clears a placement`() {
        var layout = InsightLayout()
        layout = layout.placeNew("w1", 4 to 2)
        layout = layout.remove("w1")
        assertNull(layout.placements["w1"])
    }

    @Test
    fun `projectedTo shrinks column count proportionally`() {
        var layout = InsightLayout(columnCount = 12)
        layout = layout.placeNew("w1", 8 to 2)
        val projected = layout.projectedTo(4)
        assertEquals(4, projected.columnCount)
        assertTrue(projected.placements["w1"]!!.colSpan >= 1)
    }

    @Test
    fun `all 26 widget kinds are registered`() {
        assertEquals(26, InsightWidgetKind.entries.size)
    }

    @Test
    fun `every kind has a non-blank display name`() {
        InsightWidgetKind.entries.forEach { kind ->
            assertTrue(kind.displayName.isNotBlank())
        }
    }

    @Test
    fun `all 6 themes are registered`() {
        assertEquals(6, InsightTheme.entries.size)
    }

    @Test
    fun `all 5 freshness states are registered`() {
        assertEquals(5, InsightFreshness.entries.size)
    }

    @Test
    fun `ValueFormat has 6 cases matching TypeScript`() {
        assertEquals(6, ValueFormat.entries.size)
    }

    @Test
    fun `LocalRuleBasedAdapter produces a canvas with widgets`() {
        val canvas = LocalRuleBasedAdapter.buildCanvas(testDigest)
        assertTrue("Canvas should have widgets (got ${canvas.widgets.size})", canvas.widgets.isNotEmpty())
        assertEquals(InsightTheme.AURORA, canvas.theme)
        assertTrue("Should have KPI (kinds: ${canvas.widgets.map { it.kind }})", canvas.widgets.any { it.kind == InsightWidgetKind.KPI_TILE })
        // TimeSeries is only included when digest.daily.isNotEmpty(); InMemoryInsightDataSource has empty daily
        // Donut is included when providers.size >= 2
        assertTrue("Should have Donut (kinds: ${canvas.widgets.map { it.kind }})", canvas.widgets.any { it.kind == InsightWidgetKind.DONUT })
    }

    @Test
    fun `executor handles KPI binding`() {
        val result = InsightExecutor.execute(
            InsightDataBinding.Kpi(metric = "totalCost", window = InsightTimeWindow.Last7d),
            testDigest, InsightFilter()
        )
        assertNotNull(result)
        assertTrue(result is InsightWidgetData.KPI)
    }

    @Test
    fun `executor handles TimeSeries binding`() {
        val result = InsightExecutor.execute(
            InsightDataBinding.TimeSeries(metric = "cost", window = InsightTimeWindow.Last7d),
            testDigest, InsightFilter()
        )
        assertNotNull(result)
        assertTrue(result is InsightWidgetData.TimeSeries)
    }

    @Test
    fun `executor returns Empty for macOS-only bindings`() {
        val result = InsightExecutor.execute(
            InsightDataBinding.UseCaseClusters(window = InsightTimeWindow.Last7d),
            testDigest, InsightFilter()
        )
        assertTrue(result is InsightWidgetData.Empty)
    }

    @Test
    fun `QuotaState bucket fraction is computed correctly`() {
        val bucket = InsightWidgetData.QuotaState.Bucket(
            id = "b1", providerLabel = "Anthropic", bucketName = "usage",
            symbolName = "gauge", used = 75.0, limit = 100.0
        )
        assertEquals(0.75, bucket.fraction, 0.01)
    }

    @Test
    fun `QuotaState bucket with null limit has zero fraction`() {
        val bucket = InsightWidgetData.QuotaState.Bucket(
            id = "b1", providerLabel = "Anthropic", bucketName = "usage",
            symbolName = "gauge", used = 75.0, limit = null
        )
        assertEquals(0.0, bucket.fraction, 0.01)
    }

    @Test
    fun `QuotaState bucket fraction clamps to 1`() {
        val bucket = InsightWidgetData.QuotaState.Bucket(
            id = "b1", providerLabel = "Anthropic", bucketName = "usage",
            symbolName = "gauge", used = 150.0, limit = 100.0
        )
        assertEquals(1.0, bucket.fraction, 0.01)
    }

    @Test
    fun `digest has 24 KB max encoded bytes constant`() {
        assertEquals(24 * 1024, InsightDigest.MAX_ENCODED_BYTES)
    }

    @Test
    fun `InsightAggregator builds budget and evidence index`() {
        val context = InsightAggregator.buildContext(
            digest = testDigest,
            includedDataSources = listOf("firestore_rollups", "quota_snapshots", "provider_summaries")
        )

        assertTrue(context.budgetReport.encodedBytes > 0)
        assertTrue(context.budgetReport.estimatedPromptTokens > 0)
        assertTrue(context.evidenceIndex.any { it.source == "provider_summaries" })
    }

    @Test
    fun `RuleBasedInsightAnalysisEngine returns structured result and canvas`() = runBlocking {
        val context = InsightAggregator.buildContext(
            digest = testDigest,
            includedDataSources = listOf("firestore_rollups", "quota_snapshots", "provider_summaries")
        )
        val model = InsightModelTag(
            providerKey = "local-rules",
            modelID = "local-rules-v1",
            displayName = "Local rules"
        )
        val request = InsightAnalysisRequest(
            prompt = "Why did cost spike this week?",
            context = context,
            selectedModel = model,
            instruction = InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP
        )

        val result = RuleBasedInsightAnalysisEngine(InsightAnalysisPlatform.ANDROID).analyze(request)
        val canvas = RuleBasedInsightAnalysisEngine.materializeCanvas(result, request.prompt)

        assertTrue(result.executiveSummary.isNotBlank())
        assertTrue(result.findings.isNotEmpty())
        assertTrue(result.findings.flatMap { it.evidence }.isNotEmpty())
        assertTrue(result.missionCandidates.isNotEmpty())
        assertTrue(result.missionCandidates.any { it.lens == InsightMissionCandidate.Lens.ACCRETION })
        assertTrue(result.missionCandidates.any { it.lens == InsightMissionCandidate.Lens.DILIGENCE || it.lens == InsightMissionCandidate.Lens.TECH_DEBT })
        assertTrue(result.missionCandidates.all { it.acceptanceCriteria.isNotEmpty() && it.evidence.isNotEmpty() })
        assertTrue(result.generatedWidgets.isNotEmpty())
        assertTrue(result.followUpQuestions.isNotEmpty())
        assertTrue(result.resultHash.isNotBlank())
        assertEquals(result.generatedWidgets.size, canvas.widgets.size)
        assertEquals(model, canvas.modelTag)
    }

    @Test
    fun `RuleBasedInsightAnalysisEngine uses benchmark evidence for model recommendations`() = runBlocking {
        val digest = testDigest.copy(
            modelBenchmarks = listOf(
                InsightDigest.ModelBenchmarkSummary(
                    id = "aa-claude-coding",
                    source = "artificial_analysis",
                    attribution = "Artificial Analysis",
                    fetchedAt = "2026-05-13T00:00:00Z",
                    modelID = "claude-sonnet-4-6",
                    providerID = "anthropic",
                    taskCategory = "coding",
                    score = 0.86,
                    rank = 3,
                    costSignal = 0.24,
                    confidence = 0.80,
                    freshness = "fresh",
                    blendedCostPerMtoken = 9.50
                ),
                InsightDigest.ModelBenchmarkSummary(
                    id = "da-ui-fast",
                    source = "design_arena",
                    attribution = "Design Arena",
                    fetchedAt = "2026-05-13T00:00:00Z",
                    modelID = "ui-fast-model",
                    providerID = "openai",
                    taskCategory = "design",
                    score = 0.84,
                    rank = 2,
                    costSignal = 0.82,
                    confidence = 0.78,
                    freshness = "fresh",
                    blendedCostPerMtoken = 1.20
                )
            )
        )
        val context = InsightAggregator.buildContext(
            digest = digest,
            includedDataSources = listOf("firestore_rollups", "provider_summaries", "model_benchmarks")
        )
        val model = InsightModelTag(
            providerKey = "local-rules",
            modelID = "local-rules-v1",
            displayName = "Local rules"
        )
        val request = InsightAnalysisRequest(
            prompt = "Which model should handle UI tasks?",
            context = context,
            selectedModel = model,
            instruction = InsightAnalysisRequest.Instruction.DEFAULT_BRIEF
        )

        val result = RuleBasedInsightAnalysisEngine(InsightAnalysisPlatform.ANDROID).analyze(request)

        assertTrue(result.contextBudget.includedDataSources.contains("model_benchmarks"))
        assertTrue(result.citations.any { it.kind is InsightCitation.Kind.Benchmark })
        assertTrue(result.findings.any { it.title.contains("UI/design") })
        assertTrue(result.recommendations.any { it.title.contains("cheaper") || it.rationale.contains("cost signal") })
        assertTrue(result.generatedWidgets.any { it.widget.title == "Benchmark-aware model board" })
    }

    @Test
    fun `mission enrichment fills remote results that omit missions`() = runBlocking {
        val context = InsightAggregator.buildContext(
            digest = testDigest,
            includedDataSources = listOf("firestore_rollups", "provider_summaries")
        )
        val model = InsightModelTag(
            providerKey = "remote-stub",
            modelID = "remote-stub-model",
            displayName = "Remote stub"
        )
        val request = InsightAnalysisRequest(
            prompt = "Generate the default Android Insights intelligence brief.",
            context = context,
            selectedModel = model
        )
        val remoteResult = InsightAnalysisResult(
            requestID = request.id,
            platform = InsightAnalysisPlatform.ANDROID,
            timeWindow = InsightTimeWindow.Last7d,
            executiveSummary = "Remote result without missions.",
            modelTag = model,
            contextBudget = context.budgetReport,
            resultHash = "remote-result"
        )

        val enriched = RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
            result = remoteResult,
            request = request,
            platform = InsightAnalysisPlatform.ANDROID
        )

        assertEquals("Remote result without missions.", enriched.executiveSummary)
        assertTrue(enriched.missionCandidates.isNotEmpty())
        assertNotEquals("remote-result", enriched.resultHash)
    }

    @Test
    fun `CLI agent mission snapshot exposes runtime label terminal state and feed`() {
        val snapshot = CLIAgentMissionSnapshot(
            id = "mission-1",
            title = "Run debt mission",
            status = "completed",
            requestedRuntime = "auto",
            requestedModelID = "gpt-5.5",
            selectedRuntime = "codex",
            selectedRuntimeName = "Codex",
            selectedModelID = "gpt-5.5",
            liveSummary = "Codex is summarizing the result.",
            resultPreview = "Found three high-leverage refactors.",
            errorMessage = null,
            sessionID = "thread-123",
            approvalRequestId = null,
            approvalStatus = null,
            approvalTitle = null,
            approvalMessage = null,
            createdAt = Instant.parse("2026-05-14T10:00:00Z"),
            events = listOf(
                CLIAgentMissionEvent(
                    sequence = 1,
                    timestamp = "2026-05-14T10:00:00Z",
                    kind = "status",
                    phase = "queued",
                    title = "Queued",
                    message = "Mission queued from this device.",
                    runtime = null,
                    source = "android",
                    toolName = null,
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false
                ),
                CLIAgentMissionEvent(
                    sequence = 2,
                    timestamp = "2026-05-14T10:00:10Z",
                    kind = "final_answer",
                    phase = "completed",
                    title = "Completed",
                    message = "Found three high-leverage refactors.",
                    runtime = "codex",
                    source = "mac",
                    toolName = null,
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false
                )
            )
        )

        assertEquals("Codex", snapshot.runtimeLabel)
        assertEquals(listOf("queued", "completed"), snapshot.events.map { it.phase })
        assertEquals("Found three high-leverage refactors.", snapshot.resultPreview)
        assertTrue(snapshot.isTerminal)
    }

    @Test
    fun `CLI agent mission request payload includes launch options without mutable parent events`() {
        val payload = CLIAgentMissionRequestPayloadFactory.build(
            id = "mission-123",
            title = "  Run cost mission  ",
            prompt = "  Inspect provider routing cost  ",
            missionKind = "cost_efficiency",
            requestedRuntime = "opencode",
            targetProject = "  ~/Developer/OpenBurnBar  ",
            depth = "deep",
            approvalMode = "risky_only",
            commandsAllowed = true,
            fileEditsAllowed = false,
            now = Instant.parse("2026-05-14T10:00:00Z"),
        )

        assertEquals("mission-123", payload["id"])
        assertEquals("Run cost mission", payload["title"])
        assertEquals("Inspect provider routing cost", payload["prompt"])
        assertEquals("cost_efficiency", payload["missionKind"])
        assertEquals("opencode", payload["requestedRuntime"])
        assertEquals("~/Developer/OpenBurnBar", payload["targetProject"])
        assertEquals("deep", payload["depth"])
        assertEquals("risky_only", payload["approvalMode"])
        assertEquals(true, payload["commandsAllowed"])
        assertEquals(false, payload["fileEditsAllowed"])
        assertEquals("android-insights", payload["source"])
        assertEquals("pending", payload["status"])
        assertEquals(2, payload["schemaVersion"])
        assertFalse(payload.containsKey("events"))
    }

    @Test
    fun `CLI agent mission request payload includes requested model id`() {
        val payload = CLIAgentMissionRequestPayloadFactory.build(
            id = "mission-model",
            title = "Run Codex",
            prompt = "Answer using the selected model.",
            missionKind = "chat",
            requestedRuntime = "codex",
            targetProject = null,
            depth = "standard",
            approvalMode = "existing_policy",
            commandsAllowed = false,
            fileEditsAllowed = false,
            requestedModelID = "  gpt-5.5  ",
        )

        assertEquals("codex", payload["requestedRuntime"])
        assertEquals("gpt-5.5", payload["requestedModelID"])
    }

    @Test
    fun `CLI agent mission launch contract includes all Android remote control runtimes`() {
        assertEquals(
            listOf("auto", "codex", "claude", "hermes", "openclaw", "piAgent", "opencode", "ollama"),
            MissionRuntimeTarget.entries.map { it.firestoreValue }
        )
    }

    @Test
    fun `CLI agent mission initial queued event targets durable subcollection`() {
        val event = CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(
            now = Instant.parse("2026-05-14T10:00:00Z"),
        )

        assertEquals(1, event["sequence"])
        assertEquals("2026-05-14T10:00:00Z", event["timestamp"])
        assertEquals("queued", event["phase"])
        assertEquals("status", event["kind"])
        assertEquals("android", event["source"])
        assertEquals(false, event["isError"])
    }

    @Test
    fun `CLI agent mission snapshot derives mac offline for stale queued mission`() {
        val snapshot = CLIAgentMissionSnapshot(
            id = "mission-stale",
            title = "Run modernization mission",
            status = "pending",
            requestedRuntime = "codex",
            requestedModelID = null,
            selectedRuntime = null,
            selectedRuntimeName = null,
            selectedModelID = null,
            liveSummary = "Waiting for Mac.",
            resultPreview = null,
            errorMessage = null,
            sessionID = null,
            approvalRequestId = null,
            approvalStatus = null,
            approvalTitle = null,
            approvalMessage = null,
            createdAt = Instant.now().minusSeconds(180),
            events = emptyList()
        )

        assertEquals("mac_offline", snapshot.displayStatus)
        assertTrue(snapshot.displayLiveSummary.orEmpty().contains("No signed-in Mac"))
    }

    @Test
    fun `CLI agent mission snapshot exposes pending approval state`() {
        val snapshot = CLIAgentMissionSnapshot(
            id = "mission-approval",
            title = "Run risky mission",
            status = "waiting_for_approval",
            requestedRuntime = "codex",
            requestedModelID = "gpt-5.5",
            selectedRuntime = "codex",
            selectedRuntimeName = "Codex",
            selectedModelID = "gpt-5.5",
            liveSummary = "Codex is waiting for approval before commands and file edits.",
            resultPreview = null,
            errorMessage = null,
            sessionID = null,
            approvalRequestId = "approval-1",
            approvalStatus = "pending",
            approvalTitle = "Approve Run risky mission",
            approvalMessage = "Codex is waiting for approval before commands and file edits.",
            createdAt = Instant.parse("2026-05-14T10:00:00Z"),
            events = emptyList()
        )

        assertTrue(snapshot.isWaitingForApproval)
        assertEquals("approval-1", snapshot.approvalRequestId)
        assertEquals("Approve Run risky mission", snapshot.approvalTitle)
        assertEquals("Codex is waiting for approval before commands and file edits.", snapshot.approvalMessage)
    }

    @Test
    fun `CLI agent mission snapshot exposes every required mission state`() {
        val terminalStatuses = listOf("completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed")
        val nonTerminalStatuses = listOf("queued", "accepted", "starting", "running", "waiting_for_approval")

        terminalStatuses.forEach { status ->
            val snapshot = missionSnapshot(status = status)
            assertEquals(status, snapshot.displayStatus)
            assertTrue("$status should be terminal", snapshot.isTerminal)
        }

        nonTerminalStatuses.forEach { status ->
            val snapshot = missionSnapshot(status = status, approvalStatus = if (status == "waiting_for_approval") "pending" else "none")
            assertEquals(status, snapshot.displayStatus)
            assertFalse("$status should not be terminal", snapshot.isTerminal)
        }
    }

    @Test
    fun `CLI agent mission snapshot preserves durable event ordering after resume`() {
        val snapshot = missionSnapshot(
            status = "running",
            events = listOf(
                CLIAgentMissionEvent(
                    sequence = 3,
                    timestamp = "2026-05-14T10:00:03Z",
                    kind = "tool_result",
                    phase = "process_output",
                    title = "Process",
                    message = "Tests passed.",
                    runtime = "codex",
                    source = "mac",
                    toolName = null,
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false
                ),
                CLIAgentMissionEvent(
                    sequence = 2,
                    timestamp = "2026-05-14T10:00:02Z",
                    kind = "tool_call",
                    phase = "tool_use",
                    title = "Shell",
                    message = "swift test",
                    runtime = "codex",
                    source = "mac",
                    toolName = "exec_command",
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false
                )
            ).sortedWith(compareBy<CLIAgentMissionEvent> { it.sequence }.thenBy { it.timestamp })
        )

        assertEquals(listOf(2, 3), snapshot.events.map { it.sequence })
        assertEquals(listOf("tool_call", "tool_result"), snapshot.events.map { it.kind })
        assertEquals("exec_command", snapshot.events.first().toolName)
    }

    @Test
    fun `CLI agent mission snapshot derives operator console status`() {
        val snapshot = missionSnapshot(
            status = "running",
            events = listOf(
                CLIAgentMissionEvent(
                    sequence = 1,
                    timestamp = "2026-05-14T10:00:00Z",
                    kind = "status",
                    phase = "starting",
                    title = "Starting",
                    message = "Starting Codex.",
                    runtime = "codex",
                    source = "mac",
                    toolName = null,
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false,
                ),
                CLIAgentMissionEvent(
                    sequence = 2,
                    timestamp = "2026-05-14T10:00:01Z",
                    kind = "tool_call",
                    phase = "tool_use",
                    title = "Shell",
                    message = "Running tests.",
                    runtime = "codex",
                    source = "mac",
                    toolName = "exec_command",
                    artifactPath = null,
                    changedFilePath = null,
                    isError = false,
                ),
                CLIAgentMissionEvent(
                    sequence = 3,
                    timestamp = "2026-05-14T10:00:02Z",
                    kind = "changed_file",
                    phase = "changed_file",
                    title = "Changed file",
                    message = "android/app/src/main/java/com/openburnbar/ui/insights/InsightsScreen.kt",
                    runtime = "codex",
                    source = "mac",
                    toolName = null,
                    artifactPath = null,
                    changedFilePath = "android/app/src/main/java/com/openburnbar/ui/insights/InsightsScreen.kt",
                    isError = false,
                ),
            ),
        )

        assertEquals("Changed file", snapshot.currentStepLabel)
        assertEquals("exec_command", snapshot.activeToolName)
        assertEquals("android/app/src/main/java/com/openburnbar/ui/insights/InsightsScreen.kt", snapshot.latestArtifactLabel)
    }

    private fun missionSnapshot(
        status: String,
        approvalStatus: String? = null,
        events: List<CLIAgentMissionEvent> = emptyList(),
    ) = CLIAgentMissionSnapshot(
        id = "mission-$status",
        title = "Mission $status",
        status = status,
        requestedRuntime = "codex",
        requestedModelID = null,
        selectedRuntime = "codex",
        selectedRuntimeName = "Codex",
        selectedModelID = null,
        liveSummary = "Mission is $status.",
        resultPreview = if (status == "completed") "Done." else null,
        errorMessage = if (status in setOf("failed", "unauthorized", "agent_launch_failed")) "Mission failed." else null,
        sessionID = null,
        approvalRequestId = if (status == "waiting_for_approval") "approval-1" else null,
        approvalStatus = approvalStatus,
        approvalTitle = if (status == "waiting_for_approval") "Approve Mission" else null,
        approvalMessage = if (status == "waiting_for_approval") "Codex is waiting for approval." else null,
        createdAt = Instant.now(),
        events = events
    )
}
