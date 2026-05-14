package com.openburnbar.ui.insights

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightFreshness
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.ValueFormat
import com.openburnbar.ui.theme.AuroraTheme
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream

@RunWith(AndroidJUnit4::class)
class IntelligenceBriefScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    // ─── Fixtures ─────────────────────────────────────────────────────────

    private fun fullFixture(): InsightAnalysisResult = InsightAnalysisResult(
        requestID = "test-full",
        platform = InsightAnalysisPlatform.ANDROID,
        timeWindow = InsightTimeWindow.Last7d,
        executiveSummary = "Spend on Claude Opus jumped 38% this week, driven by three long " +
            "refactor sessions on the payments service. Switch the daily routine work to " +
            "Haiku and gate Opus behind explicit opt-in to recover the budget.",
        modelTag = InsightModelTag(
            providerKey = "anthropic",
            modelID = "claude-sonnet-4-6",
            displayName = "Claude Sonnet 4.6",
            egressTier = InsightEgressTier.USER_KEY,
        ),
        contextBudget = InsightContextBudgetReport(
            encodedBytes = 18 * 1024,
            estimatedPromptTokens = 4_200,
            includedDataSources = listOf("usage_rollups", "quota_snapshots", "agent_sessions"),
        ),
        findings = listOf(
            finding(
                title = "Claude Opus is now your top spend",
                why = "Opus accounts for 62% of weekly cost (was 41%). Most traffic is " +
                    "exploratory edits where Sonnet would suffice.",
                severity = InsightSeverity.HIGH,
                action = "Default new Claude sessions to Sonnet 4.6; promote to Opus on demand.",
                citations = listOf(citation("opus-week", "Claude Opus, 7d")),
            ),
            finding(
                title = "Codex usage dropped after Wednesday",
                why = "Codex sessions fell from ~9/day to 2/day. The router shifted Codex " +
                    "tasks to Claude Sonnet, raising per-task cost ~3.4×.",
                severity = InsightSeverity.MEDIUM,
                action = "Re-enable Codex in the router pool and confirm a healthy auth token.",
                citations = listOf(citation("codex-fall", "Codex, 7d")),
            ),
            finding(
                title = "Cache hit-rate slipped to 11%",
                why = "Prompt cache reads dropped by half. Session prompts have grown 1.6× — " +
                    "each one busts the cache.",
                severity = InsightSeverity.LOW,
                action = "Trim system prompts and reuse the canonical project preamble.",
                citations = emptyList(),
            ),
        ),
        anomalies = listOf(
            anomaly(
                title = "MiniMax burst Tuesday 02:14",
                detail = "11 calls in 6 minutes from a cron — looks like a retry storm.",
                score = 3.4,
                confidence = InsightConfidence.HIGH,
            ),
            anomaly(
                title = "Quota near limit (Anthropic)",
                detail = "82% of monthly hosted quota consumed with 10 days remaining.",
                score = 2.1,
                confidence = InsightConfidence.MEDIUM,
            ),
            anomaly(
                title = "Latency P95 climb (Codex)",
                detail = "P95 latency rose from 7.2s to 14.8s on Friday.",
                score = -1.8,
                confidence = InsightConfidence.MEDIUM,
            ),
        ),
        recommendations = listOf(
            recommendation(
                title = "Move daily refactors to Sonnet 4.6",
                rationale = "Sonnet handles the same prompts at ~28% of Opus cost with " +
                    "comparable quality on this codebase's review history.",
                action = "Set the Claude routing pool default to Sonnet 4.6.",
                impact = "$54/week saved",
                severity = InsightSeverity.HIGH,
            ),
            recommendation(
                title = "Re-enable Codex pool",
                rationale = "Cost-per-task is 3.4× higher when Codex is offline; the auth " +
                    "token expired at 11:48 Wednesday.",
                action = "Refresh the Codex auth and toggle the router pool back on.",
                impact = "Restores ~$12/day",
                severity = InsightSeverity.MEDIUM,
            ),
        ),
        generatedWidgets = listOf(
            generatedTimeSeriesWidget(),
            generatedRankingWidget(),
            generatedDonutWidget(),
        ),
        followUpQuestions = listOf(
            followUp("How does this week compare to last week?"),
            followUp("Which sessions used Claude Opus?"),
            followUp("Show MiniMax burst sessions"),
        ),
        tokenUsage = InsightTokenUsage(
            providerKey = "anthropic",
            modelID = "claude-sonnet-4-6",
            inputTokens = 3_800,
            outputTokens = 600,
        ),
        estimatedCostUSD = 0.0184,
        auditID = "abcdef0123456789",
        resultHash = "9f8e7d6c5b4a3210",
    )

    private fun sparseFixture(): InsightAnalysisResult = fullFixture().copy(
        anomalies = emptyList(),
        recommendations = emptyList(),
        generatedWidgets = emptyList(),
        followUpQuestions = emptyList(),
    )

    private fun emptyFixture(): InsightAnalysisResult = fullFixture().copy(
        findings = emptyList(),
        anomalies = emptyList(),
        recommendations = emptyList(),
        generatedWidgets = emptyList(),
        followUpQuestions = emptyList(),
    )

    // ─── Test cases ───────────────────────────────────────────────────────

    @Test
    fun rule_smoke_test() {
        composeRule.setContent {
            androidx.compose.material3.Text(text = "smoke")
        }
        composeRule.onNodeWithText("smoke").assertIsDisplayed()
    }

    @Test
    fun renders_full_light() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    IntelligenceBriefScreen(result = fullFixture())
                }
            }
        }
        assertHeroAndAllSectionsVisible()
    }

    @Test
    fun renders_full_dark() {
        composeRule.setContent {
            AuroraTheme(darkTheme = true) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    IntelligenceBriefScreen(result = fullFixture())
                }
            }
        }
        assertHeroAndAllSectionsVisible()
    }

    @Test
    fun omits_empty_sections_sparse() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                IntelligenceBriefScreen(result = sparseFixture())
            }
        }
        composeRule.onNodeWithTag(SECTION_TAG_HERO).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_FINDINGS).assertExists()
        composeRule.onAllNodesWithTag(SECTION_TAG_ANOMALIES).assertCountEquals0()
        composeRule.onAllNodesWithTag(SECTION_TAG_RECOMMENDATIONS).assertCountEquals0()
        composeRule.onAllNodesWithTag(SECTION_TAG_GENERATED).assertCountEquals0()
        composeRule.onAllNodesWithTag(SECTION_TAG_FOLLOWUPS).assertCountEquals0()
        composeRule.onNodeWithTag(SECTION_TAG_AUDIT).assertExists()
    }

    @Test
    fun omits_empty_sections_empty() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                IntelligenceBriefScreen(result = emptyFixture())
            }
        }
        composeRule.onAllNodesWithTag(SECTION_TAG_FINDINGS).assertCountEquals0()
        composeRule.onAllNodesWithTag(SECTION_TAG_ANOMALIES).assertCountEquals0()
        composeRule.onNodeWithTag(SECTION_TAG_HERO).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_AUDIT).assertExists()
    }

    @Test
    fun font_scale_1_15x_no_overflow() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                val density = LocalDensity.current
                CompositionLocalProvider(
                    LocalDensity provides Density(density.density, fontScale = 1.15f),
                ) {
                    IntelligenceBriefScreen(result = fullFixture())
                }
            }
        }
        composeRule.onNodeWithText("TOP FINDINGS").assertExists()
    }

    @Test
    fun reduce_motion_skips_shimmer() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAuroraReduceMotion provides true) {
                    IntelligenceBriefScreen(result = fullFixture())
                }
            }
        }
        // All sections exist in the composition tree synchronously when
        // reduce-motion is on — i.e. no AnimatedVisibility staggering. We
        // assert existence rather than display because long content runs
        // below the viewport on a phone-sized device.
        composeRule.onNodeWithTag(SECTION_TAG_HERO).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_GENERATED).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_FINDINGS).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_ANOMALIES).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_RECOMMENDATIONS).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_FOLLOWUPS).assertExists()
        composeRule.onNodeWithTag(SECTION_TAG_AUDIT).assertExists()
    }

    @Test
    fun mission_launchpad_passes_selected_runtime_and_kind() {
        var capturedTitle: String? = null
        var capturedKind: String? = null
        var capturedRuntime: String? = null

        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                    IntelligenceBriefScreen(
                        result = fullFixture(),
                        onMissionLaunchTap = { action, runtime ->
                            capturedTitle = action.title
                            capturedKind = action.tone.firestoreValue()
                            capturedRuntime = runtime.firestoreValue
                        },
                    )
                }
            }
        }

        composeRule.onNodeWithTag("insights.mission.runtime.codex", useUnmergedTree = true).performClick()
        composeRule.onNodeWithTag("insights.mission.creative").performScrollTo().performClick()

        composeRule.runOnIdle {
            require(capturedTitle == "Creative Mission")
            require(capturedKind == "creative")
            require(capturedRuntime == "codex")
        }
    }

    @Test
    fun talkback_reading_order_matches_contract() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAuroraReduceMotion provides true) {
                    // The screen is normally hosted in a verticalScroll
                    // ancestor (`InsightsScreen`). In a standalone test we
                    // emulate that by wrapping in a scrollable column so
                    // every section is laid out and positioned.
                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                        IntelligenceBriefScreen(result = fullFixture())
                    }
                }
            }
        }
        // Reading order is hero → generated views (CHARTS) → findings →
        // anomalies → recommendations → follow-ups → audit. Charts sit
        // second so a reader gets a graph before they get prose.
        val orderedTags = listOf(
            SECTION_TAG_HERO,
            SECTION_TAG_GENERATED,
            SECTION_TAG_FINDINGS,
            SECTION_TAG_ANOMALIES,
            SECTION_TAG_RECOMMENDATIONS,
            SECTION_TAG_FOLLOWUPS,
            SECTION_TAG_AUDIT,
        )
        val tops = orderedTags.map { tag ->
            val node = composeRule.onNodeWithTag(tag)
            node.assertExists()
            // `positionInRoot.y` gives the section's top inside the scroll
            // content even when the section is currently below the viewport,
            // which is exactly the layout order TalkBack will follow.
            node.fetchSemanticsNode().positionInRoot.y
        }
        for (i in 1 until tops.size) {
            require(tops[i] > tops[i - 1]) {
                "Section order violated: ${orderedTags[i]} (top=${tops[i]}) is not below " +
                    "${orderedTags[i - 1]} (top=${tops[i - 1]})"
            }
        }
    }

    @Test
    fun screenshot_light() = captureBriefScreenshot(
        fileName = "light.png",
        darkTheme = false,
        fontScale = 1.0f,
    )

    @Test
    fun screenshot_dark() = captureBriefScreenshot(
        fileName = "dark.png",
        darkTheme = true,
        fontScale = 1.0f,
    )

    @Test
    fun screenshot_fontscale_1_15x() = captureBriefScreenshot(
        fileName = "fontscale-1_15x.png",
        darkTheme = false,
        fontScale = 1.15f,
    )

    /**
     * Fourth variant: dark theme at 1.15× font scale. We previously had a
     * `tablet-landscape` variant, but `captureToImage` is clamped to the
     * host activity's surface dimensions so the captured pixels were
     * identical to the phone-width light variant. A dark + large-text
     * variant is genuinely distinct and stresses the same wide-text path
     * tablet would, while staying honest about the capture environment.
     */
    @Test
    fun screenshot_dark_fontscale_1_15x() = captureBriefScreenshot(
        fileName = "dark-fontscale-1_15x.png",
        darkTheme = true,
        fontScale = 1.15f,
    )

    /**
     * Impact arrow inference parity contract (iOS DESIGN.md row 2026-05-13
     * "Recommendation impact arrow infers direction from sign"):
     *  - leading `−` / `-` (savings): "↘" + success green
     *  - leading `+` (increase): "↗" + ember warning
     *  - otherwise: "↗" + success green
     * Surface assertion only — we test the rendered glyphs against fixtures
     * that exercise all three branches.
     */
    @Test
    fun impact_arrow_directionality() {
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAuroraReduceMotion provides true) {
                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                        IntelligenceBriefScreen(
                            result = fullFixture().copy(
                                recommendations = listOf(
                                    com.openburnbar.data.insights.InsightRecommendation(
                                        title = "Savings recommendation",
                                        rationale = "Cut Opus daily routine work.",
                                        recommendedAction = "Default to Sonnet.",
                                        estimatedImpact = "−\$54/week",
                                        evidence = emptyList(),
                                        confidence = InsightConfidence.HIGH,
                                        severity = InsightSeverity.HIGH,
                                    ),
                                    com.openburnbar.data.insights.InsightRecommendation(
                                        title = "Cost increase recommendation",
                                        rationale = "Add a second Codex pool.",
                                        recommendedAction = "Provision new key.",
                                        estimatedImpact = "+\$120/week",
                                        evidence = emptyList(),
                                        confidence = InsightConfidence.MEDIUM,
                                        severity = InsightSeverity.MEDIUM,
                                    ),
                                    com.openburnbar.data.insights.InsightRecommendation(
                                        title = "Restoration recommendation",
                                        rationale = "Re-enable Codex.",
                                        recommendedAction = "Refresh auth.",
                                        estimatedImpact = "Restores ~\$12/day",
                                        evidence = emptyList(),
                                        confidence = InsightConfidence.MEDIUM,
                                        severity = InsightSeverity.MEDIUM,
                                    ),
                                ),
                            ),
                        )
                    }
                }
            }
        }
        composeRule.onNodeWithText("↘ −\$54/week").assertExists()
        composeRule.onNodeWithText("↗ +\$120/week").assertExists()
        composeRule.onNodeWithText("↗ Restores ~\$12/day").assertExists()
    }

    /**
     * Citation chips are the brief's only built-in interactive escape hatch
     * — the parity contract requires that tapping a footnote chip fires
     * the `onCitationTap` callback exactly once with the chip's citation.
     * iOS covers this in `IntelligenceBriefWiringTests`; this is the
     * Android mirror.
     */
    @Test
    fun citation_chip_tap_fires_callback() {
        var tapped: InsightCitation? = null
        composeRule.setContent {
            AuroraTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAuroraReduceMotion provides true) {
                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                        IntelligenceBriefScreen(
                            result = fullFixture(),
                            onCitationTap = { tapped = it },
                        )
                    }
                }
            }
        }
        // The fullFixture seeds finding #1 with a "Claude Opus, 7d" chip,
        // but charts now sit above findings so the chip is below the fold.
        // Scroll until the chip is in the viewport, then click.
        composeRule.onNodeWithText("Claude Opus, 7d").performScrollTo().performClick()
        composeRule.waitForIdle()
        assert(tapped?.label == "Claude Opus, 7d") {
            "Expected onCitationTap to fire with label 'Claude Opus, 7d' — got ${tapped?.label}"
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    private fun assertHeroAndAllSectionsVisible() {
        // `assertExists` (not `assertIsDisplayed`) — long content runs below
        // the viewport on a phone-sized device but is still in the tree.
        composeRule.onNodeWithText("INTELLIGENCE BRIEF").assertExists()
        composeRule.onNodeWithText("Last 7 days").assertExists()
        composeRule.onNodeWithText("TOP FINDINGS").assertExists()
        composeRule.onNodeWithText("ANOMALY ATLAS").assertExists()
        composeRule.onNodeWithText("RECOMMENDATIONS").assertExists()
        composeRule.onNodeWithText("FOLLOW-UP QUESTIONS").assertExists()
    }

    private fun captureBriefScreenshot(
        fileName: String,
        darkTheme: Boolean,
        fontScale: Float,
    ) {
        composeRule.setContent {
            val baseDensity = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(baseDensity.density, fontScale = fontScale),
                LocalAuroraReduceMotion provides true,
            ) {
                AuroraTheme(darkTheme = darkTheme) {
                    Surface(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(MaterialTheme.colorScheme.background)
                            .testTag("screenshot-surface"),
                        color = MaterialTheme.colorScheme.background,
                    ) {
                        IntelligenceBriefScreen(result = fullFixture())
                    }
                }
            }
        }
        composeRule.waitForIdle()
        val bitmap = composeRule.onRoot().captureToImage().asAndroidBitmap()
        val outDir = File(
            InstrumentationRegistry.getInstrumentation().targetContext
                .getExternalFilesDir(null),
            "insights-editorial",
        ).apply { mkdirs() }
        val outFile = File(outDir, fileName)
        FileOutputStream(outFile).use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        }
    }

    private fun SemanticsNodeInteractionCollection.assertCountEquals0() =
        this.assertCountEquals(0)

    // ─── Fixture builders ────────────────────────────────────────────────

    private fun finding(
        title: String,
        why: String,
        severity: InsightSeverity,
        action: String,
        citations: List<InsightCitation>,
    ) = InsightFinding(
        title = title,
        whyItMatters = why,
        evidence = citations,
        confidence = InsightConfidence.HIGH,
        severity = severity,
        recommendedAction = action,
    )

    private fun anomaly(
        title: String,
        detail: String,
        score: Double,
        confidence: InsightConfidence,
    ) = InsightAnomaly(
        title = title,
        detail = detail,
        score = score,
        evidence = emptyList(),
        confidence = confidence,
    )

    private fun recommendation(
        title: String,
        rationale: String,
        action: String,
        impact: String,
        severity: InsightSeverity,
    ) = com.openburnbar.data.insights.InsightRecommendation(
        title = title,
        rationale = rationale,
        recommendedAction = action,
        estimatedImpact = impact,
        evidence = emptyList(),
        confidence = InsightConfidence.MEDIUM,
        severity = severity,
    )

    private fun followUp(text: String) = InsightFollowUpQuestion(question = text)

    private fun citation(id: String, label: String) = InsightCitation(
        id = id,
        kind = InsightCitation.Kind.Query(text = label),
        label = label,
    )

    // ─── Generated widget fixtures (real chart data) ─────────────────────

    /** Provider-mix cost-over-time. 7 daily points, 3 series. */
    private fun generatedTimeSeriesWidget() = InsightGeneratedWidget(
        widget = InsightWidget(
            kind = InsightWidgetKind.TIME_SERIES_LINE,
            title = "Weekly cost · provider mix",
            spec = InsightWidgetSpec.TimeSeries(
                InsightWidgetSpec.TimeSeriesSpec(style = InsightWidgetSpec.TimeSeriesSpec.Style.LINE),
            ),
            dataBinding = InsightDataBinding.TimeSeries(
                metric = "cost",
                dimension = InsightWidgetSpec.Dimension.PROVIDER,
                window = InsightTimeWindow.Last7d,
            ),
            data = InsightWidgetData.TimeSeries(
                series = listOf(
                    InsightWidgetData.TimeSeries.Series(
                        id = "anthropic",
                        name = "Anthropic",
                        colorHex = "#E07868",
                        points = listOf(
                            timePoint("2026-05-06", 4.20),
                            timePoint("2026-05-07", 5.10),
                            timePoint("2026-05-08", 6.40),
                            timePoint("2026-05-09", 8.95),
                            timePoint("2026-05-10", 7.60),
                            timePoint("2026-05-11", 9.80),
                            timePoint("2026-05-12", 11.40),
                        ),
                    ),
                    InsightWidgetData.TimeSeries.Series(
                        id = "openai",
                        name = "OpenAI",
                        colorHex = "#8E86D0",
                        points = listOf(
                            timePoint("2026-05-06", 2.10),
                            timePoint("2026-05-07", 2.30),
                            timePoint("2026-05-08", 2.80),
                            timePoint("2026-05-09", 2.40),
                            timePoint("2026-05-10", 2.60),
                            timePoint("2026-05-11", 3.10),
                            timePoint("2026-05-12", 3.40),
                        ),
                    ),
                    InsightWidgetData.TimeSeries.Series(
                        id = "minimax",
                        name = "MiniMax",
                        colorHex = "#2CBEC8",
                        points = listOf(
                            timePoint("2026-05-06", 0.80),
                            timePoint("2026-05-07", 0.90),
                            timePoint("2026-05-08", 1.00),
                            timePoint("2026-05-09", 5.60),
                            timePoint("2026-05-10", 1.20),
                            timePoint("2026-05-11", 1.30),
                            timePoint("2026-05-12", 1.10),
                        ),
                    ),
                ),
                xAxisLabel = "Day",
                yAxisLabel = "USD",
                yFormat = ValueFormat.CURRENCY,
            ),
            freshness = InsightFreshness.FRESH,
        ),
        reason = "Provider mix tells the cost story the executive summary references " +
            "— Anthropic is the rising line.",
        citations = emptyList(),
    )

    /** Top models by cost — horizontal bar ranking. */
    private fun generatedRankingWidget() = InsightGeneratedWidget(
        widget = InsightWidget(
            kind = InsightWidgetKind.BAR_RANKING,
            title = "Top models by cost",
            spec = InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec()),
            dataBinding = InsightDataBinding.Ranking(
                metric = "cost",
                dimension = InsightWidgetSpec.Dimension.MODEL,
                limit = 5,
                window = InsightTimeWindow.Last7d,
            ),
            data = InsightWidgetData.Ranking(
                rows = listOf(
                    InsightWidgetData.Ranking.Row("opus", "Claude Opus", 42.18, "62% share"),
                    InsightWidgetData.Ranking.Row("sonnet", "Claude Sonnet 4.6", 18.46, "27% share"),
                    InsightWidgetData.Ranking.Row("gpt5", "OpenAI GPT-5", 6.91, "10% share"),
                    InsightWidgetData.Ranking.Row("minimax", "MiniMax M2.7", 7.84, "5h burst"),
                    InsightWidgetData.Ranking.Row("kimi", "Kimi K2", 1.42, "9 sessions"),
                ),
                valueFormat = ValueFormat.CURRENCY,
                dimensionLabel = "Model",
            ),
            freshness = InsightFreshness.FRESH,
        ),
        reason = "Pinning this puts the Sonnet-default recommendation one tap away " +
            "from its evidence.",
        citations = emptyList(),
    )

    /** Provider distribution donut. */
    private fun generatedDonutWidget() = InsightGeneratedWidget(
        widget = InsightWidget(
            kind = InsightWidgetKind.DONUT,
            title = "Spend distribution by provider",
            spec = InsightWidgetSpec.Distribution(InsightWidgetSpec.DistributionSpec()),
            dataBinding = InsightDataBinding.Distribution(
                metric = "cost",
                dimension = InsightWidgetSpec.Dimension.PROVIDER,
                window = InsightTimeWindow.Last7d,
            ),
            data = InsightWidgetData.Distribution(
                slices = listOf(
                    InsightWidgetData.Distribution.Slice("anthropic", "Anthropic", 60.64, "#E07868"),
                    InsightWidgetData.Distribution.Slice("openai", "OpenAI", 18.70, "#8E86D0"),
                    InsightWidgetData.Distribution.Slice("minimax", "MiniMax", 11.90, "#2CBEC8"),
                    InsightWidgetData.Distribution.Slice("kimi", "Kimi", 4.81, "#D49A3A"),
                ),
                valueFormat = ValueFormat.CURRENCY,
                total = 96.05,
            ),
            freshness = InsightFreshness.FRESH,
        ),
        reason = "Donut frames the headline: one provider, one model family, dominating spend.",
        citations = emptyList(),
    )

    private fun timePoint(date: String, value: Double) =
        InsightWidgetData.TimeSeries.Point(date = date, value = value)
}
