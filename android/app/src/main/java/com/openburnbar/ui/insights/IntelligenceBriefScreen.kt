package com.openburnbar.ui.insights

import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTheme as CanvasTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlinx.coroutines.delay

/**
 * Editorial Observatory rewrite of the Intelligence Brief surface.
 *
 * Single-column layout, generous margins, footnote citation chips, mono
 * ordinal findings, anomaly instrument tray, ember-seal recommendations,
 * inline ClickableText follow-ups, and a mercury-hairline audit footer.
 *
 * Cross-platform parity with `IntelligenceBriefView` (Swift): identical
 * section order, copy, chip labels, accessibility order, and motion
 * behavior. The function signature is intentionally unchanged so the host
 * `InsightsScreen` keeps wiring through `(result = it)`.
 *
 * Story arc (no exceptions):
 *  1. Hero — eyebrow + time-window subtitle + 22sp headline + mono meta
 *     strip + mercury hairline (one shimmer sweep on appear).
 *  2. Top findings — mono ordinals (01/02/03…).
 *  3. Anomalies — `LazyRow` "instrument tray" with mono z-score numerals.
 *  4. Recommendations — ember seal top-right + mono impact arrow.
 *  5. Generated views — inline widget renderer + pin action.
 *  6. Follow-up questions — inline whimsy `ClickableText` segments.
 *  7. Audit footer — full-width mercury hairline + mono meta.
 */
@Composable
fun IntelligenceBriefScreen(
    result: InsightAnalysisResult,
    modifier: Modifier = Modifier,
    onCitationTap: (InsightCitation) -> Unit = {},
    onFollowUpTap: (InsightFollowUpQuestion) -> Unit = {},
    onMissionLaunchTap: (MissionLaunchAction, MissionLaunchOptions) -> Unit = { _, _ -> },
    onPinWidget: (InsightGeneratedWidget) -> Unit = {},
    onConfigureModel: (() -> Unit)? = null,
    onUpgradeToPro: (() -> Unit)? = null,
    onShowAudit: (() -> Unit)? = null,
    theme: CanvasTheme = CanvasTheme.AURORA,
) {
    val isDark = isSystemInDarkTheme()
    val reduceMotion = rememberReduceMotion()

    // Section visibility — one boolean per story-arc slot. Cascade-in is
    // driven by a single LaunchedEffect that flips entries with a 40ms
    // stagger. Reduce-motion paints everything instantly.
    val visibility = rememberSectionVisibility(reduceMotion)

    var expandedMissionID by remember(result.id) { mutableStateOf<String?>(null) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xl.dp),
    ) {
        AnimatedSection(visible = visibility[0], reduceMotion = reduceMotion) {
            HeroSection(
                result = result,
                isDark = isDark,
                reduceMotion = reduceMotion,
                onConfigureModel = onConfigureModel,
                onUpgradeToPro = onUpgradeToPro,
                onCitationTap = onCitationTap,
            )
        }

        AnimatedSection(visible = visibility[1], reduceMotion = reduceMotion) {
            MissionLaunchpad(onSelect = { action, options ->
                onMissionLaunchTap(action, options)
            })
        }

        if (result.findings.isNotEmpty()) {
            AnimatedSection(visible = visibility[2], reduceMotion = reduceMotion) {
                FindingsSection(
                    findings = result.findings,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.missionCandidates.isNotEmpty()) {
            AnimatedSection(visible = visibility[3], reduceMotion = reduceMotion) {
            MissionBoardSection(
                missions = result.missionCandidates,
                expandedMissionID = expandedMissionID,
                onToggle = { missionID ->
                    expandedMissionID = if (expandedMissionID == missionID) null else missionID
                },
                onLaunch = { mission ->
                    onMissionLaunchTap(
                        mission.launchAction(),
                        MissionLaunchOptions(
                            requestedRuntime = MissionRuntimeTarget.AUTO.firestoreValue,
                            targetProject = mission.projectDisplayName ?: mission.projectID,
                            depth = MissionDepth.STANDARD.firestoreValue,
                            approvalMode = MissionApprovalMode.EXISTING.firestoreValue,
                            commandsAllowed = false,
                            fileEditsAllowed = false,
                        ),
                    )
                },
                onCitationTap = onCitationTap,
            )
        }
        }

        if (result.anomalies.isNotEmpty()) {
            AnimatedSection(visible = visibility[4], reduceMotion = reduceMotion) {
                AnomalyAtlasSection(
                    anomalies = result.anomalies,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.recommendations.isNotEmpty()) {
            AnimatedSection(visible = visibility[5], reduceMotion = reduceMotion) {
                RecommendationsSection(
                    recommendations = result.recommendations,
                    isDark = isDark,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.generatedWidgets.isNotEmpty()) {
            AnimatedSection(visible = visibility[6], reduceMotion = reduceMotion) {
                GeneratedViewsSection(
                    generated = result.generatedWidgets,
                    figureStart = 1,
                    theme = theme,
                    onPin = onPinWidget,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.followUpQuestions.isNotEmpty()) {
            AnimatedSection(visible = visibility[7], reduceMotion = reduceMotion) {
                FollowUpSection(
                    questions = result.followUpQuestions,
                    isDark = isDark,
                    onTap = onFollowUpTap,
                )
            }
        }

        AnimatedSection(visible = visibility[8], reduceMotion = reduceMotion) {
            AuditFooterSection(
                result = result,
                isDark = isDark,
                onShowAudit = onShowAudit,
            )
        }
    }
}

// ─── Section visibility cascade ────────────────────────────────────────────

@Composable
private fun rememberSectionVisibility(reduceMotion: Boolean): SnapshotStateList<Boolean> {
    val state = remember { MutableList(SECTION_COUNT) { false }.toMutableStateList() }
    LaunchedEffect(reduceMotion) {
        if (reduceMotion) {
            for (i in 0 until SECTION_COUNT) state[i] = true
        } else {
            for (i in 0 until SECTION_COUNT) {
                state[i] = true
                delay(40L)
            }
        }
    }
    return state
}

private const val SECTION_COUNT = 9

@Composable
private fun AnimatedSection(
    visible: Boolean,
    reduceMotion: Boolean,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    if (reduceMotion) {
        // No motion: paint synchronously, identical visual outcome.
        content()
        return
    }
    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(
            animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f),
            initialOffsetY = { with(density) { 8.dp.roundToPx() } },
        ) + fadeIn(animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f)),
    ) {
        content()
    }
}

// ─── Hero ─────────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroSection(
    result: InsightAnalysisResult,
    isDark: Boolean,
    reduceMotion: Boolean,
    onConfigureModel: (() -> Unit)?,
    onUpgradeToPro: (() -> Unit)?,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_HERO),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        val answer = result.briefingAnswer
        Text(
            text = (answer?.let { answerEyebrow(it) } ?: EYEBROW).uppercase(),
            style = AuroraType.caption.copy(letterSpacing = 2.4.sp),
            color = if (answer?.isFallback == true) InsightsColors.kpiNeutral else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.semantics { contentDescription = answer?.let { answerEyebrow(it) } ?: EYEBROW_DESCRIPTION },
        )
        Text(
            text = IntelligenceBriefFormatting.windowLabel(result.timeWindow),
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (answer != null) {
            Text(
                text = "Q · ${answer.question}",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        ) {
            val leadProvider = heroLeadProvider(result)
            if (leadProvider != null) {
                ProviderLogo(
                    provider = leadProvider,
                    size = 44.dp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Text(
                text = result.executiveSummary,
                style = AuroraType.title.copy(
                    fontFamily = FontFamily.SansSerif,
                    fontSize = 22.sp,
                    lineHeight = 30.8.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.semantics { heading() },
            )
        }
        if (answer != null) {
            AnswerPanel(
                answer = answer,
                onCitationTap = onCitationTap,
                onConfigureModel = onConfigureModel,
                onUpgradeToPro = onUpgradeToPro,
            )
        }
        MetaStrip(
            modelTag = result.modelTag,
            budget = result.contextBudget,
            tokenUsage = result.tokenUsage,
            costUSD = result.estimatedCostUSD,
            onConfigureModel = onConfigureModel,
        )
        MercuryHairline(
            isDark = isDark,
            reduceMotion = reduceMotion,
            shimmer = true,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AnswerPanel(
    answer: InsightBriefingAnswer,
    onCitationTap: (InsightCitation) -> Unit,
    onConfigureModel: (() -> Unit)? = null,
    onUpgradeToPro: (() -> Unit)? = null,
) {
    val showUpgradeToProCTA = onUpgradeToPro != null &&
        answer.modelDisplayName == InsightBriefingAnswer.SUBSCRIPTION_REQUIRED_DISPLAY_NAME
    val showConnectModelCTA = onConfigureModel != null && !showUpgradeToProCTA && when (answer.source) {
        InsightBriefingAnswer.Source.LOCAL_RULES ->
            answer.modelDisplayName.contains("no LLM configured", ignoreCase = true)
        // After the BurnBar-hosted fallback answered, promote the
        // "connect your own model" CTA so the user can swap to their
        // own route for the next turn.
        InsightBriefingAnswer.Source.HOSTED_FALLBACK -> true
        InsightBriefingAnswer.Source.MODEL_GATEWAY -> false
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.68f))
            .border(BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(8.dp))
            .padding(AuroraSpacing.md.dp)
            // Mirrors Swift `.animation(.easeOut(duration: 0.08), value: answer.answer)`.
            // Keeps the panel from popping when streaming `.delta` chunks
            // append to `answer.answer` token-by-token.
            .animateContentSize(),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Text(
            text = answer.answer,
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (answer.bullets.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
            ) {
                answer.bullets.take(4).forEach { bullet ->
                    Text(
                        text = bullet,
                        style = AuroraType.monoTiny,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .border(BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(999.dp))
                            .padding(horizontal = AuroraSpacing.sm.dp, vertical = 3.dp),
                    )
                }
            }
        }
        if (answer.citations.isNotEmpty()) {
            CitationChipRow(citations = answer.citations, onTap = onCitationTap)
        }
        if (showUpgradeToProCTA) {
            onUpgradeToPro?.let { upgradeAction ->
                // "Upgrade to BurnBar Pro" CTA — mirrors the Swift
                // BriefingAnswerPanel paywall button. Surfaces only
                // when the orchestrator caught a subscription-required
                // rejection from the hosted Cloud Function, so
                // existing free-tier users with their own LLM
                // configured never see this prompt.
                androidx.compose.material3.Button(
                    onClick = upgradeAction,
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = InsightsColors.kpiPositive.copy(alpha = 0.20f),
                        contentColor = InsightsColors.kpiPositive,
                    ),
                    modifier = Modifier
                        .padding(top = 2.dp)
                        .semantics {
                            contentDescription = "Upgrade to BurnBar Pro. Unlocks the BurnBar-hosted Intelligence Brief AI answers. Subscription required."
                        },
                ) {
                    Text(
                        text = "Upgrade to BurnBar Pro",
                        style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    )
                }
            }
        } else if (showConnectModelCTA) {
            onConfigureModel?.let { configureModel ->
                // "Connect a model" CTA — mirrors the Swift BriefingAnswerPanel
                // button. Surfaces only when the user has zero LLM gateways
                // configured so the eyebrow's "Data summary · no LLM configured"
                // honesty is paired with a one-tap path out.
                androidx.compose.material3.Button(
                    onClick = configureModel,
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = InsightsColors.kpiPositive.copy(alpha = 0.16f),
                        contentColor = InsightsColors.kpiPositive,
                    ),
                    modifier = Modifier
                        .padding(top = 2.dp)
                        .semantics {
                            contentDescription = "Connect a model. Opens the Insights model picker so a connected gateway can author the reply."
                        },
                ) {
                    Text(
                        text = "Connect a model",
                        style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    )
                }
            }
        }
    }
}

/**
 * Mirror of iOS `heroLeadProvider`. Returns the first resolvable
 * `AgentProvider` referenced by the lead finding's evidence, falling back
 * through top-level result citations. Powers the 44dp brand mark to the
 * left of the executive summary so the brief gains visual identity at a
 * glance before the user reads a word.
 */
private fun heroLeadProvider(result: InsightAnalysisResult): AgentProvider? {
    val candidates = (result.findings.firstOrNull()?.evidence.orEmpty()) + result.citations
    for (citation in candidates) {
        val kind = citation.kind
        if (kind is InsightCitation.Kind.Agent) {
            AgentProvider.fromKey(kind.provider)?.let { return it }
        }
    }
    return null
}

/**
 * Resolves the brand provider for a citation so a tiny brand mark can lead
 * each chip. Session/Quota citations carry an agent provider key in their
 * `provider` field; pure `.agent(...)` citations use `kind.provider`.
 */
private fun citationProvider(citation: InsightCitation): AgentProvider? {
    return when (val kind = citation.kind) {
        is InsightCitation.Kind.Agent -> AgentProvider.fromKey(kind.provider)
        is InsightCitation.Kind.Session -> kind.provider?.let { AgentProvider.fromKey(it) }
        is InsightCitation.Kind.Quota -> AgentProvider.fromKey(kind.provider)
        else -> null
    }
}

private fun answerEyebrow(answer: InsightBriefingAnswer): String =
    when {
        answer.isFallback -> "Answered locally after LLM fallback"
        answer.source == InsightBriefingAnswer.Source.MODEL_GATEWAY -> "Answered by ${answer.modelDisplayName}"
        // The BurnBar-hosted fallback answered (OpenRouter → MiniMax).
        // Surface it explicitly so the user understands their own
        // route wasn't used and can connect one if they want.
        answer.source == InsightBriefingAnswer.Source.HOSTED_FALLBACK ->
            "Answered by ${answer.modelDisplayName} · hosted fallback"
        // Mirrors Swift `heroEyebrowText`: don't claim to "answer" when
        // there's no LLM behind it — the local rule engine only
        // summarizes the digest. Same wording, same accessibility intent.
        else -> "Data summary · ${answer.modelDisplayName}"
    }

// ─── Mission Control ───────────────────────────────────────────────────────

data class MissionLaunchAction(
    val title: String,
    val subtitle: String,
    val tone: MissionTone,
    val prompt: String,
) {
    fun followUpQuestion(): InsightFollowUpQuestion =
        InsightFollowUpQuestion(
            question = prompt.trimIndent(),
            rationale = "Turns the current brief into a local-agent mission.",
        )
}

enum class MissionTone {
    CREATIVE,
    DILIGENCE,
    DEBT,
    ACCRETIVE,
    SECURITY,
    UI_IMPROVEMENT,
    MODERNIZATION,
    PROVIDER_ROUTING,
    COST_EFFICIENCY,
    PROJECT_FOCUS,
    CUSTOM,
}

enum class MissionRuntimeTarget(
    val firestoreValue: String,
    val label: String,
) {
    AUTO("auto", "Auto"),
    CODEX("codex", "Codex"),
    CLAUDE("claude", "Claude"),
    HERMES("hermes", "Hermes"),
    OPENCLAW("openclaw", "OpenClaw"),
    PI_AGENT("piAgent", "Pi"),
    OPENCODE("opencode", "OpenCode"),
    OLLAMA("ollama", "Ollama"),
}

enum class MissionDepth(val firestoreValue: String, val label: String) {
    LIGHT("light", "Light"),
    STANDARD("standard", "Standard"),
    DEEP("deep", "Deep"),
    MAX("max", "Max"),
}

enum class MissionApprovalMode(val firestoreValue: String, val label: String) {
    EXISTING("existing_policy", "Existing"),
    MANUAL("manual_all", "Manual"),
    RISKY("risky_only", "Risky"),
    READ_ONLY("read_only", "Read only"),
}

data class MissionLaunchOptions(
    val requestedRuntime: String,
    val targetProject: String?,
    val depth: String,
    val approvalMode: String,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
)

fun MissionTone.firestoreValue(): String = when (this) {
    MissionTone.CREATIVE -> "creative"
    MissionTone.DILIGENCE -> "diligence"
    MissionTone.DEBT -> "debt"
    MissionTone.ACCRETIVE -> "accretive"
    MissionTone.SECURITY -> "security"
    MissionTone.UI_IMPROVEMENT -> "ui_improvement"
    MissionTone.MODERNIZATION -> "modernization"
    MissionTone.PROVIDER_ROUTING -> "provider_routing"
    MissionTone.COST_EFFICIENCY -> "cost_efficiency"
    MissionTone.PROJECT_FOCUS -> "project_focus"
    MissionTone.CUSTOM -> "custom"
}

private val missionLaunchActions = listOf(
    MissionLaunchAction(
        title = "Creative Mission",
        subtitle = "Accretive features, UI improvements, modernizations.",
        tone = MissionTone.CREATIVE,
        prompt = """
            Create a creative/accretive mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, user value, implementation surface, acceptance criteria, evidence to inspect, likely risks, and how mobile should show the result. Also recommend adjacent missions for UI improvements, modernizations, and small features that compound product value.
        """,
    ),
    MissionLaunchAction(
        title = "Diligence Mission",
        subtitle = "Security, reliability, launch-readiness evidence.",
        tone = MissionTone.DILIGENCE,
        prompt = """
            Create a diligence mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, launch-readiness/security/reliability questions, exact evidence to collect, severity model, acceptance criteria, and the mobile result summary I should expect. Also recommend adjacent security, QA, and production-readiness missions when the data supports them.
        """,
    ),
    MissionLaunchAction(
        title = "Debt Mission",
        subtitle = "Compounding drag, rewrite risk, focused remediation.",
        tone = MissionTone.DEBT,
        prompt = """
            Create a technical debt mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, project/module focus, debt hypothesis, delivery drag, validation commands, acceptance criteria, remediation sequence, and how mobile should summarize progress. Also recommend adjacent modernization, dependency, architecture, and UI cleanup missions when the evidence supports them.
        """,
    ),
    MissionLaunchAction(
        title = "Accretive Mission",
        subtitle = "Small compounding product or workflow wins.",
        tone = MissionTone.ACCRETIVE,
        prompt = """
            Create an accretive product mission from this Insights brief. Identify the smallest compounding feature or workflow improvement, the target project, the best local agent/runtime, acceptance criteria, evidence to inspect, and how mobile should stream progress and final artifacts.
        """,
    ),
    MissionLaunchAction(
        title = "Security Mission",
        subtitle = "Trust boundaries, abuse paths, hardening work.",
        tone = MissionTone.SECURITY,
        prompt = """
            Create a security mission from this Insights brief. Identify trust boundaries, risky data paths, likely abuse cases, validation commands, approval requirements, and the exact evidence the local Mac agent should collect before proposing changes.
        """,
    ),
    MissionLaunchAction(
        title = "UI Mission",
        subtitle = "Operator surfaces, visual polish, accessibility.",
        tone = MissionTone.UI_IMPROVEMENT,
        prompt = """
            Create a UI improvement mission from this Insights brief. Identify the most operator-visible screen or flow, the UX defect to fix, target files, visual acceptance criteria, accessibility checks, and the mobile timeline events I should expect while the Mac agent works.
        """,
    ),
    MissionLaunchAction(
        title = "Modernization Mission",
        subtitle = "Migrations, stale APIs, compatibility cleanup.",
        tone = MissionTone.MODERNIZATION,
        prompt = """
            Create a modernization mission from this Insights brief. Identify outdated architecture, dependencies, APIs, or code organization, the safest migration path, compatibility constraints, tests to run, and rollback risks.
        """,
    ),
    MissionLaunchAction(
        title = "Routing Mission",
        subtitle = "Model selection, fallback, quota-aware routing.",
        tone = MissionTone.PROVIDER_ROUTING,
        prompt = """
            Create a provider-routing mission from this Insights brief. Inspect routing policy, fallback behavior, quota state, model selection, and account-level failover, then recommend the highest-leverage routing fix with validation steps.
        """,
    ),
    MissionLaunchAction(
        title = "Cost Mission",
        subtitle = "Spend reduction without quality loss.",
        tone = MissionTone.COST_EFFICIENCY,
        prompt = """
            Create a cost-efficiency mission from this Insights brief. Find the highest-confidence spend reduction, target providers or models, expected savings, quality risks, validation queries, and implementation steps.
        """,
    ),
    MissionLaunchAction(
        title = "Focus Mission",
        subtitle = "Repo focus, priority, next best outcome.",
        tone = MissionTone.PROJECT_FOCUS,
        prompt = """
            Create a project-focus mission from this Insights brief. Identify the repo or surface consuming the most attention, the most valuable next outcome, distractions to avoid, evidence to collect, and a focused execution plan.
        """,
    ),
    MissionLaunchAction(
        title = "Custom Mission",
        subtitle = "Dispatch the current brief as a flexible prompt.",
        tone = MissionTone.CUSTOM,
        prompt = """
            Create a custom local-agent mission from this Insights brief. Preserve the brief context, choose the best runtime, name the target project, list acceptance criteria, and stream all reasoning, tool calls, tool results, changed files, and final answer back to mobile.
        """,
    ),
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MissionLaunchpad(onSelect: (MissionLaunchAction, MissionLaunchOptions) -> Unit) {
    var selectedRuntime by remember { mutableStateOf(MissionRuntimeTarget.AUTO) }
    var targetProject by remember { mutableStateOf("") }
    var selectedDepth by remember { mutableStateOf(MissionDepth.STANDARD) }
    var selectedApprovalMode by remember { mutableStateOf(MissionApprovalMode.EXISTING) }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    val launchOptions = MissionLaunchOptions(
        requestedRuntime = selectedRuntime.firestoreValue,
        targetProject = targetProject.trim().ifBlank { null },
        depth = selectedDepth.firestoreValue,
        approvalMode = selectedApprovalMode.firestoreValue,
        commandsAllowed = commandsAllowed,
        fileEditsAllowed = fileEditsAllowed,
    )
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = "MISSION CONTROL")
        Text(
            text = "Create a dispatch-ready mission for your local Hermes, Pi, OpenClaw, Claude, and Codex agents.",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(MissionRuntimeTarget.values().asList()) { runtime ->
                val selected = runtime == selectedRuntime
                TextButton(
                    onClick = { selectedRuntime = runtime },
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(
                            if (selected) MaterialTheme.colorScheme.onSurface
                            else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
                        )
                        .testTag("insights.mission.runtime.${runtime.firestoreValue}")
                        .semantics { contentDescription = "Run mission on ${runtime.label}" },
                ) {
                    Text(
                        text = runtime.label,
                        style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = if (selected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        MissionOptionsPanel(
            targetProject = targetProject,
            onTargetProjectChange = { targetProject = it },
            selectedDepth = selectedDepth,
            onDepthChange = { selectedDepth = it },
            selectedApprovalMode = selectedApprovalMode,
            onApprovalModeChange = { selectedApprovalMode = it },
            commandsAllowed = commandsAllowed,
            onCommandsAllowedChange = { commandsAllowed = it },
            fileEditsAllowed = fileEditsAllowed,
            onFileEditsAllowedChange = { fileEditsAllowed = it },
        )
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            missionLaunchActions.forEach { action ->
                MissionLaunchButton(action = action, options = launchOptions, onSelect = onSelect)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MissionOptionsPanel(
    targetProject: String,
    onTargetProjectChange: (String) -> Unit,
    selectedDepth: MissionDepth,
    onDepthChange: (MissionDepth) -> Unit,
    selectedApprovalMode: MissionApprovalMode,
    onApprovalModeChange: (MissionApprovalMode) -> Unit,
    commandsAllowed: Boolean,
    onCommandsAllowedChange: (Boolean) -> Unit,
    fileEditsAllowed: Boolean,
    onFileEditsAllowedChange: (Boolean) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .border(BorderStroke(0.75.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(AuroraRadius.sm.dp))
            .padding(AuroraSpacing.sm.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        OutlinedTextField(
            value = targetProject,
            onValueChange = onTargetProjectChange,
            label = { Text("Target project path on Mac") },
            singleLine = true,
            textStyle = AuroraType.caption,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("insights.mission.targetProject"),
        )
        MissionOptionChips(
            title = "Depth",
            entries = MissionDepth.entries,
            selected = selectedDepth,
            label = { it.label },
            onSelect = onDepthChange,
        )
        MissionOptionChips(
            title = "Approval",
            entries = MissionApprovalMode.entries,
            selected = selectedApprovalMode,
            label = { it.label },
            onSelect = onApprovalModeChange,
        )
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        ) {
            MissionBooleanChip(
                label = "Commands",
                selected = commandsAllowed,
                onClick = { onCommandsAllowedChange(!commandsAllowed) },
                tag = "insights.mission.commandsAllowed",
            )
            MissionBooleanChip(
                label = "File edits",
                selected = fileEditsAllowed,
                onClick = { onFileEditsAllowedChange(!fileEditsAllowed) },
                tag = "insights.mission.fileEditsAllowed",
            )
        }
    }
}

@Composable
private fun <T> MissionOptionChips(
    title: String,
    entries: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = title,
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
            items(entries) { entry ->
                MissionBooleanChip(
                    label = label(entry),
                    selected = entry == selected,
                    onClick = { onSelect(entry) },
                    tag = null,
                )
            }
        }
    }
}

@Composable
private fun MissionBooleanChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    tag: String?,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
            )
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
    ) {
        Text(
            text = label,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = if (selected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MissionLaunchButton(
    action: MissionLaunchAction,
    options: MissionLaunchOptions,
    onSelect: (MissionLaunchAction, MissionLaunchOptions) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val color = when (action.tone) {
        MissionTone.CREATIVE -> AuroraColors.whimsy(isDark)
        MissionTone.DILIGENCE -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
        MissionTone.DEBT -> AuroraColors.ember(isDark)
        MissionTone.ACCRETIVE -> InsightsColors.kpiPositive
        MissionTone.SECURITY -> InsightsColors.kpiNegative
        MissionTone.UI_IMPROVEMENT -> MaterialTheme.colorScheme.primary
        MissionTone.MODERNIZATION -> MaterialTheme.colorScheme.onSurfaceVariant
        MissionTone.PROVIDER_ROUTING -> if (isDark) AuroraColors.goldDark else AuroraColors.gold
        MissionTone.COST_EFFICIENCY -> InsightsColors.kpiNeutral
        MissionTone.PROJECT_FOCUS -> MaterialTheme.colorScheme.onSurfaceVariant
        MissionTone.CUSTOM -> MaterialTheme.colorScheme.onSurface
    }
    val icon = when (action.tone) {
        MissionTone.CREATIVE -> Icons.Filled.AutoAwesome
        MissionTone.DILIGENCE -> Icons.Filled.VerifiedUser
        MissionTone.DEBT -> Icons.Filled.Build
        else -> Icons.Filled.NorthEast
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.sm.dp))
            .border(BorderStroke(0.75.dp, color.copy(alpha = 0.32f)), RoundedCornerShape(AuroraRadius.sm.dp))
            .clickable { onSelect(action, options) }
            .padding(AuroraSpacing.md.dp)
            .testTag("insights.mission.${action.tone.firestoreValue()}")
            .semantics { contentDescription = action.title },
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier
                .padding(top = 1.dp)
                .size(22.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = action.title,
                style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "${action.subtitle} Run on ${missionRuntimeLabel(options.requestedRuntime)}.",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
            )
        }
        Icon(
            imageVector = Icons.Filled.NorthEast,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(top = 2.dp)
                .size(16.dp),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MetaStrip(
    modelTag: InsightModelTag,
    budget: InsightContextBudgetReport,
    tokenUsage: InsightTokenUsage?,
    costUSD: Double?,
    onConfigureModel: (() -> Unit)?,
) {
    val parts = buildList {
        add(modelTag.displayName)
        add(modelTag.egressTier.displayLabel)
        add(IntelligenceBriefFormatting.budgetLabel(budget))
        if (tokenUsage != null) add(IntelligenceBriefFormatting.tokenUsageLabel(tokenUsage, costUSD))
    }
    // Append the `·` separator to the END of every non-final token (glued
    // with NBSP so it never wraps off its preceding word). `FlowRow` wraps
    // between children, so this keeps the dot trailing the line above
    // instead of orphaning at the start of the next line.
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        parts.forEachIndexed { index, label ->
            val text = if (index < parts.size - 1) "$label\u00A0·" else label
            Text(
                text = text,
                style = AuroraType.monoSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (onConfigureModel != null) {
            TextButton(
                onClick = onConfigureModel,
                modifier = Modifier.semantics { contentDescription = "Adjust model" },
            ) {
                Text(text = "Adjust", style = AuroraType.monoSmall)
            }
        }
    }
}

// ─── Mercury hairline ──────────────────────────────────────────────────────

@Composable
private fun MercuryHairline(
    isDark: Boolean,
    reduceMotion: Boolean,
    shimmer: Boolean,
) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    val baseBrush = remember(mercury, aureate) {
        Brush.linearGradient(listOf(mercury, aureate))
    }

    val phase = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(shimmer, reduceMotion) {
        if (shimmer && !reduceMotion) {
            phase.snapTo(0f)
            phase.animateTo(
                targetValue = 1f,
                animationSpec = androidx.compose.animation.core.tween(
                    durationMillis = AuroraMotion.mercuryShimmerDuration.toInt(),
                    easing = androidx.compose.animation.core.EaseInOut,
                ),
            )
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(baseBrush)
            .drawWithContent {
                drawContent()
                if (!reduceMotion && phase.value > 0f && phase.value < 1f) {
                    val width = size.width
                    val bandWidth = width * 0.18f
                    val center = phase.value * (width + bandWidth) - bandWidth / 2f
                    val shimmerBrush = Brush.linearGradient(
                        colors = listOf(
                            Color.White.copy(alpha = 0.0f),
                            Color.White.copy(alpha = 0.25f),
                            Color.White.copy(alpha = 0.0f),
                        ),
                        start = Offset(center - bandWidth / 2f, 0f),
                        end = Offset(center + bandWidth / 2f, 0f),
                    )
                    drawRect(shimmerBrush)
                }
            }
            .semantics { contentDescription = "Mercury divider" },
    )
}

// ─── Findings ─────────────────────────────────────────────────────────────

@Composable
private fun FindingsSection(
    findings: List<InsightFinding>,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_FINDINGS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        SectionHeader(title = SECTION_FINDINGS_TITLE)
        findings.take(3).forEachIndexed { index, finding ->
            FindingRow(
                ordinal = index + 1,
                finding = finding,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun FindingRow(
    ordinal: Int,
    finding: InsightFinding,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val (severityColor, severityLabel) = finding.severity.palette(isDark)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        // 3dp leading severity bar — full row height — mirrors iOS FindingRow.
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(severityColor),
        )
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "%02d".format(ordinal),
                    style = AuroraType.monoSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
                Text(
                    text = severityLabel.uppercase(),
                    style = AuroraType.monoTiny.copy(letterSpacing = 1.4.sp),
                    color = severityColor,
                )
                Spacer(modifier = Modifier.weight(1f))
                ConfidenceDots(confidence = finding.confidence)
            }
            Text(
                text = finding.title,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (finding.whyItMatters.isNotBlank()) {
                Text(
                    text = finding.whyItMatters,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (finding.evidence.isNotEmpty()) {
                CitationChipRow(citations = finding.evidence, onTap = onCitationTap)
            }
            if (finding.recommendedAction.isNotBlank()) {
                ActionStripe(text = finding.recommendedAction)
            }
        }
    }
}

@Composable
private fun ConfidenceDots(confidence: InsightConfidence) {
    val isDark = isSystemInDarkTheme()
    val whimsy = AuroraColors.whimsy(isDark)
    val filled = when (confidence) {
        InsightConfidence.LOW -> 1
        InsightConfidence.MEDIUM -> 2
        InsightConfidence.HIGH -> 3
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics {
            contentDescription = "Confidence ${confidence.name.lowercase()}"
        },
    ) {
        repeat(3) { index ->
            Box(
                modifier = Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (index < filled) whimsy else whimsy.copy(alpha = 0.25f)),
            )
        }
    }
}

// ─── Mission Board ────────────────────────────────────────────────────────

@Composable
private fun MissionBoardSection(
    missions: List<InsightMissionCandidate>,
    expandedMissionID: String?,
    onToggle: (String) -> Unit,
    onLaunch: (InsightMissionCandidate) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_MISSIONS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_MISSIONS_TITLE)
        missions.forEach { mission ->
            MissionCard(
                mission = mission,
                expanded = expandedMissionID == mission.id,
                onToggle = { onToggle(mission.id) },
                onLaunch = { onLaunch(mission) },
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun MissionCard(
    mission: InsightMissionCandidate,
    expanded: Boolean,
    onToggle: () -> Unit,
    onLaunch: () -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val lensColor = missionLensColor(mission.lens)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.sm.dp))
            .border(
                BorderStroke(if (expanded) 1.dp else 0.5.dp, lensColor.copy(alpha = if (expanded) 0.55f else 0.28f)),
                RoundedCornerShape(AuroraRadius.sm.dp),
            )
            .clickable(onClick = onToggle)
            .padding(AuroraSpacing.md.dp)
            .semantics {
                contentDescription = "Mission ${missionLensLabel(mission.lens)}, ${missionPriorityLabel(mission.priority)} priority, ${mission.title}"
            },
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = missionLensLabel(mission.lens).uppercase(),
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                color = lensColor,
            )
            Text(
                text = missionPriorityLabel(mission.priority).uppercase(),
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                color = missionPriorityColor(mission.priority),
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                text = mission.effort.name.lowercase().uppercase(),
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = if (expanded) "Close" else "Open",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = onLaunch,
                modifier = Modifier.testTag("insights.mission.candidate.${mission.launchAction().tone.firestoreValue()}"),
            ) {
                Text(
                    text = "Launch Mission",
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                    color = lensColor,
                )
            }
        }
        Text(
            text = mission.title,
            style = AuroraType.headline,
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (mission.summary.isNotBlank()) {
            Text(
                text = mission.summary,
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (expanded) {
            if (mission.expectedImpact.isNotBlank()) {
                ActionStripe(text = mission.expectedImpact)
            }
            mission.acceptanceCriteria.take(5).forEachIndexed { index, criterion ->
                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                    Text(
                        text = "${index + 1}.",
                        style = AuroraType.monoTiny,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        text = criterion,
                        style = AuroraType.body,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
            if (mission.evidence.isNotEmpty()) {
                CitationChipRow(citations = mission.evidence, onTap = onCitationTap)
            }
        }
    }
}

private fun missionRuntimeLabel(rawValue: String): String =
    MissionRuntimeTarget.entries.firstOrNull { it.firestoreValue == rawValue }?.label ?: rawValue

private fun InsightMissionCandidate.launchAction(): MissionLaunchAction {
    val kind = dispatchMetadata["missionKind"] ?: when (lens) {
        InsightMissionCandidate.Lens.ACCRETION -> "accretive"
        InsightMissionCandidate.Lens.DILIGENCE -> "diligence"
        InsightMissionCandidate.Lens.TECH_DEBT -> "debt"
        InsightMissionCandidate.Lens.ROUTING -> "provider_routing"
        InsightMissionCandidate.Lens.QUOTA -> "cost_efficiency"
        InsightMissionCandidate.Lens.FOCUS -> "project_focus"
    }
    val criteria = acceptanceCriteria.take(4).joinToString(separator = "\n") { "- $it" }
    val evidenceLabels = evidence.take(6).joinToString(separator = ", ") { it.label }
    return MissionLaunchAction(
        title = title,
        subtitle = summary.ifBlank { "Recommended mission from this brief." },
        tone = MissionTone.entries.firstOrNull { it.firestoreValue() == kind } ?: MissionTone.CUSTOM,
        prompt = """
            Launch this recommended $kind mission from the current Intelligence Brief.

            Title: $title
            Summary: $summary
            Expected impact: $expectedImpact
            Target project: ${projectDisplayName ?: projectID ?: "Use the brief evidence to choose the safest target project."}
            Acceptance criteria:
            ${criteria.ifBlank { "- Define acceptance criteria from the brief evidence." }}
            Evidence: ${evidenceLabels.ifBlank { "Use the current brief citations and findings." }}
        """,
    )
}

private fun missionLensLabel(lens: InsightMissionCandidate.Lens): String =
    when (lens) {
        InsightMissionCandidate.Lens.ACCRETION -> "Accretion"
        InsightMissionCandidate.Lens.DILIGENCE -> "Diligence"
        InsightMissionCandidate.Lens.TECH_DEBT -> "Debt"
        InsightMissionCandidate.Lens.ROUTING -> "Routing"
        InsightMissionCandidate.Lens.QUOTA -> "Quota"
        InsightMissionCandidate.Lens.FOCUS -> "Focus"
    }

private fun missionPriorityLabel(priority: InsightMissionCandidate.Priority): String =
    when (priority) {
        InsightMissionCandidate.Priority.LOW -> "Low"
        InsightMissionCandidate.Priority.MEDIUM -> "Medium"
        InsightMissionCandidate.Priority.HIGH -> "High"
        InsightMissionCandidate.Priority.CRITICAL -> "Critical"
    }

@Composable
private fun missionLensColor(lens: InsightMissionCandidate.Lens): Color =
    when (lens) {
        InsightMissionCandidate.Lens.ACCRETION -> InsightsColors.kpiPositive
        InsightMissionCandidate.Lens.DILIGENCE -> if (isSystemInDarkTheme()) AuroraColors.goldDark else AuroraColors.gold
        InsightMissionCandidate.Lens.TECH_DEBT -> AuroraColors.ember(isSystemInDarkTheme())
        InsightMissionCandidate.Lens.ROUTING -> MaterialTheme.colorScheme.primary
        InsightMissionCandidate.Lens.QUOTA -> InsightsColors.kpiNeutral
        InsightMissionCandidate.Lens.FOCUS -> MaterialTheme.colorScheme.onSurfaceVariant
    }

@Composable
private fun missionPriorityColor(priority: InsightMissionCandidate.Priority): Color =
    when (priority) {
        InsightMissionCandidate.Priority.LOW -> MaterialTheme.colorScheme.onSurfaceVariant
        InsightMissionCandidate.Priority.MEDIUM -> InsightsColors.kpiNeutral
        InsightMissionCandidate.Priority.HIGH -> AuroraColors.ember(isSystemInDarkTheme())
        InsightMissionCandidate.Priority.CRITICAL -> InsightsColors.kpiNegative
    }

// ─── Anomaly Atlas ────────────────────────────────────────────────────────

@Composable
private fun AnomalyAtlasSection(
    anomalies: List<InsightAnomaly>,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_ANOMALIES),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_ANOMALIES_TITLE)
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(end = AuroraSpacing.md.dp),
        ) {
            items(anomalies) { anomaly ->
                AnomalyInstrumentCell(anomaly = anomaly, onCitationTap = onCitationTap)
            }
        }
    }
}

@Composable
private fun AnomalyInstrumentCell(
    anomaly: InsightAnomaly,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val accessibilityLabel = "Anomaly ${anomaly.title}, z score %.1f".format(anomaly.score)
    val markerColor = when {
        kotlin.math.abs(anomaly.score) >= 3.0 -> InsightsColors.kpiNegative
        kotlin.math.abs(anomaly.score) >= 2.0 -> AuroraColors.ember(isDark)
        else -> InsightsColors.kpiNeutral
    }
    Column(
        modifier = Modifier
            .width(220.dp)
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .clickable {
                anomaly.evidence.firstOrNull()?.let(onCitationTap)
            }
            .padding(AuroraSpacing.md.dp)
            .semantics { contentDescription = accessibilityLabel },
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        Text(
            text = "z %.1f".format(anomaly.score),
            style = AuroraType.monoLarge.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
            color = markerColor,
        )
        ZScoreGauge(
            score = anomaly.score,
            markerColor = markerColor,
            rule = MaterialTheme.colorScheme.outlineVariant,
        )
        Text(
            text = anomaly.title,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
        )
        if (anomaly.detail.isNotBlank()) {
            Text(
                text = anomaly.detail,
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
            )
        }
        ConfidenceChip(confidence = anomaly.confidence)
    }
}

/**
 * Slim instrument scale showing where the z-score lands relative to the
 * conventional ±2σ threshold. Single Canvas: hairline axis, faint warning
 * band beyond ±2σ, tick at z = 0, ticks at ±2σ, and a filled marker dot.
 *
 * Domain auto-extends so |z| > 3 still fits: domain = `max(3, ceil(|score|))`.
 */
@Composable
private fun ZScoreGauge(
    score: Double,
    markerColor: Color,
    rule: Color,
) {
    val domain = maxOf(3.0, kotlin.math.ceil(kotlin.math.abs(score)))
    val clamped = score.coerceIn(-domain, domain).toFloat()
    val warningTint = markerColor.copy(alpha = 0.10f)
    androidx.compose.foundation.Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(12.dp),
    ) {
        val width = size.width
        val height = size.height
        val centerY = height / 2f
        val fraction = (clamped + domain.toFloat()) / (2f * domain.toFloat())
        val zeroX = width * 0.5f
        val markerX = (width * fraction).coerceIn(2.dp.toPx(), width - 2.dp.toPx())
        val thresholdOffset = (2f / domain.toFloat()) * (width / 2f)

        // Warning bands (|z| ≥ 2σ)
        drawRect(
            color = warningTint,
            topLeft = Offset(0f, centerY - 4.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(zeroX - thresholdOffset, 8.dp.toPx()),
        )
        drawRect(
            color = warningTint,
            topLeft = Offset(zeroX + thresholdOffset, centerY - 4.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(width - (zeroX + thresholdOffset), 8.dp.toPx()),
        )

        // Axis
        drawLine(
            color = rule,
            start = Offset(0f, centerY),
            end = Offset(width, centerY),
            strokeWidth = 0.5.dp.toPx(),
        )

        // Zero tick
        drawLine(
            color = rule,
            start = Offset(zeroX, centerY - 4.dp.toPx()),
            end = Offset(zeroX, centerY + 4.dp.toPx()),
            strokeWidth = 0.75.dp.toPx(),
        )

        // ±2σ ticks (subtle, half-height)
        listOf(zeroX - thresholdOffset, zeroX + thresholdOffset).forEach { tickX ->
            drawLine(
                color = rule.copy(alpha = 0.6f),
                start = Offset(tickX, centerY - 2.5.dp.toPx()),
                end = Offset(tickX, centerY + 2.5.dp.toPx()),
                strokeWidth = 0.5.dp.toPx(),
            )
        }

        // Marker dot
        drawCircle(
            color = markerColor,
            radius = 2.dp.toPx(),
            center = Offset(markerX, centerY),
        )
    }
}

// ─── Recommendations ──────────────────────────────────────────────────────

@Composable
private fun RecommendationsSection(
    recommendations: List<InsightRecommendation>,
    isDark: Boolean,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_RECOMMENDATIONS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_RECOMMENDATIONS_TITLE)
        recommendations.forEach { rec ->
            RecommendationCard(
                recommendation = rec,
                isDark = isDark,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun RecommendationCard(
    recommendation: InsightRecommendation,
    isDark: Boolean,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .padding(AuroraSpacing.md.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SeverityChip(severity = recommendation.severity)
                    ConfidenceChip(confidence = recommendation.confidence)
                }
                EmberSeal(severity = recommendation.severity, isDark = isDark)
            }
            Text(
                text = recommendation.title,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (recommendation.rationale.isNotBlank()) {
                Text(
                    text = recommendation.rationale,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (recommendation.recommendedAction.isNotBlank()) {
                ActionStripe(text = recommendation.recommendedAction)
            }
            recommendation.estimatedImpact
                ?.takeIf { it.isNotBlank() }
                ?.let { impact ->
                    val (arrow, color, descLabel) = impactArrow(
                        impact = impact,
                        isDark = isDark,
                    )
                    Text(
                        text = "$arrow $impact",
                        style = AuroraType.monoSmall,
                        color = color,
                        modifier = Modifier.semantics {
                            contentDescription = "Estimated impact, $descLabel $impact"
                        },
                    )
                }
            if (recommendation.evidence.isNotEmpty()) {
                CitationChipRow(citations = recommendation.evidence, onTap = onCitationTap)
            }
        }
    }
}

/**
 * Sign-aware impact arrow + color, mirroring the iOS audit row
 * "Recommendation impact arrow infers direction from sign":
 *   - leading `−` / `-` (e.g. `−$54/week`): `↘` + success green (savings)
 *   - leading `+` (e.g. `+$120/week`): `↗` + ember warning (cost increase)
 *   - otherwise (e.g. `$54/week saved`, `Restores ~$12/day`): `↗` + success
 *     green, because the brief only emits non-prefixed strings for net
 *     positive recommendations. This avoids rewarding cost increases with
 *     the same green used for savings.
 *
 * Returned `descLabel` feeds the accessibility description so TalkBack
 * announces "savings of $54/week" or "increase of $120/week" instead of
 * the raw glyph.
 */
private data class ImpactArrow(val arrow: String, val color: Color, val descLabel: String)

@Composable
private fun impactArrow(impact: String, isDark: Boolean): ImpactArrow {
    val trimmed = impact.trim()
    return when {
        trimmed.startsWith("−") || trimmed.startsWith("-") -> ImpactArrow(
            arrow = "↘",
            color = if (isDark) AuroraColors.successDark else AuroraColors.success,
            descLabel = "savings of",
        )
        trimmed.startsWith("+") -> ImpactArrow(
            arrow = "↗",
            color = AuroraColors.ember(isDark),
            descLabel = "increase of",
        )
        else -> ImpactArrow(
            arrow = "↗",
            color = if (isDark) AuroraColors.successDark else AuroraColors.success,
            descLabel = "estimated",
        )
    }
}

/**
 * Severity-aware ember seal. HIGH/CRITICAL recommendations get a full
 * ember→blaze gradient — they're the ones the reader's eye should jump
 * to. MEDIUM/LOW/INFO get a muted ring so the seal stays informative
 * rather than decorative.
 */
@Composable
private fun EmberSeal(severity: InsightSeverity, isDark: Boolean) {
    val ember = AuroraColors.ember(isDark)
    val blaze = AuroraColors.blaze
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val border = MaterialTheme.colorScheme.outlineVariant
    val highImpact = severity == InsightSeverity.HIGH || severity == InsightSeverity.CRITICAL
    val accessibilityLabel = if (highImpact) {
        "High-impact recommendation"
    } else {
        "Recommendation seal, severity ${severity.name.lowercase()}"
    }
    Box(
        modifier = Modifier
            .size(16.dp)
            .clip(CircleShape)
            .drawBehind {
                if (highImpact) {
                    drawCircle(
                        brush = Brush.linearGradient(
                            colors = listOf(ember, blaze),
                            start = Offset.Zero,
                            end = Offset(size.width, size.height),
                        ),
                    )
                    drawCircle(
                        color = border,
                        radius = size.minDimension / 2f,
                        style = Stroke(width = 0.5.dp.toPx()),
                    )
                } else {
                    drawCircle(
                        color = muted.copy(alpha = 0.08f),
                    )
                    drawCircle(
                        color = muted.copy(alpha = 0.5f),
                        radius = size.minDimension / 2f,
                        style = Stroke(width = 0.5.dp.toPx()),
                    )
                }
            }
            .semantics { contentDescription = accessibilityLabel },
    )
}

// ─── Generated views ──────────────────────────────────────────────────────

@Composable
private fun GeneratedViewsSection(
    generated: List<InsightGeneratedWidget>,
    figureStart: Int,
    theme: CanvasTheme,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_GENERATED),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_GENERATED_TITLE)
        generated.forEachIndexed { index, item ->
            GeneratedView(
                figureOrdinal = figureStart + index,
                generated = item,
                theme = theme,
                isDark = isDark,
                onPin = onPin,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun GeneratedView(
    figureOrdinal: Int,
    generated: InsightGeneratedWidget,
    theme: CanvasTheme,
    isDark: Boolean,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .padding(AuroraSpacing.md.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            ) {
                Text(
                    text = "Fig. %02d".format(figureOrdinal),
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = generated.widget.title,
                    style = AuroraType.headline,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { onPin(generated) },
                    modifier = Modifier.semantics { contentDescription = "Pin to canvas" },
                ) {
                    Text(
                        text = "Pin",
                        style = AuroraType.monoSmall,
                    )
                }
            }
            InsightWidgetRenderer(
                widget = generated.widget,
                onCitationTap = onCitationTap,
                theme = theme,
                showHeader = false,
            )
            if (generated.citations.isNotEmpty()) {
                CitationChipRow(
                    citations = generated.citations,
                    onTap = onCitationTap,
                )
            }
            if (generated.reason.isNotBlank()) {
                FigureCaption(reason = generated.reason, isDark = isDark)
            }
        }
    }
}

/**
 * Editorial-print figure caption: a 1.5dp tall mercury rule on the leading
 * edge with mono caption text. Replaces the previous bare text line for the
 * generated-view reason.
 */
@Composable
private fun FigureCaption(reason: String, isDark: Boolean) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Box(
            modifier = Modifier
                .width(1.5.dp)
                .height(AuroraSpacing.lg.dp)
                .background(Brush.verticalGradient(listOf(mercury, aureate))),
        )
        Text(
            text = reason,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ─── Follow-ups ───────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FollowUpSection(
    questions: List<InsightFollowUpQuestion>,
    isDark: Boolean,
    onTap: (InsightFollowUpQuestion) -> Unit,
) {
    val whimsy = AuroraColors.whimsy(isDark)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_FOLLOWUPS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_FOLLOWUPS_TITLE)
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        ) {
            questions.forEachIndexed { index, question ->
                if (index > 0) {
                    Text(
                        text = SEPARATOR,
                        style = AuroraType.body,
                        color = muted,
                    )
                }
                FollowUpClickable(
                    question = question,
                    color = whimsy,
                    onTap = onTap,
                )
            }
        }
    }
}

@Composable
private fun FollowUpClickable(
    question: InsightFollowUpQuestion,
    color: Color,
    onTap: (InsightFollowUpQuestion) -> Unit,
) {
    val annotated = remember(question, color) {
        buildAnnotatedString {
            withStyle(
                SpanStyle(
                    color = color,
                    textDecoration = TextDecoration.Underline,
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.Medium,
                ),
            ) {
                append(question.question)
            }
        }
    }
    Text(
        text = annotated,
        style = AuroraType.body,
        modifier = Modifier
            .clickable { onTap(question) }
            .semantics { contentDescription = "Ask: ${question.question}" },
    )
}

// ─── Audit footer ─────────────────────────────────────────────────────────

@Composable
private fun AuditFooterSection(
    result: InsightAnalysisResult,
    isDark: Boolean,
    onShowAudit: (() -> Unit)?,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_AUDIT),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        MercuryHairline(isDark = isDark, reduceMotion = true, shimmer = false)
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = IntelligenceBriefFormatting.auditFooter(result),
                style = AuroraType.monoSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
                maxLines = 2,
            )
            if (onShowAudit != null) {
                TextButton(
                    onClick = onShowAudit,
                    modifier = Modifier.semantics { contentDescription = "Open audit log" },
                ) {
                    Text(text = "Audit log", style = AuroraType.monoSmall)
                }
            }
        }
    }
}

// ─── Shared section header ────────────────────────────────────────────────

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = AuroraType.caption.copy(letterSpacing = 2.0.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.semantics { heading() },
    )
}

// ─── Chips ────────────────────────────────────────────────────────────────

@Composable
private fun SeverityChip(severity: InsightSeverity) {
    val isDark = isSystemInDarkTheme()
    val (color, label) = severity.palette(isDark)
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, color.copy(alpha = 0.6f)),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Severity ${label.lowercase()}" },
    ) {
        Text(
            text = label.uppercase(),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
            color = color,
        )
    }
}

private fun InsightSeverity.palette(isDark: Boolean): Pair<Color, String> = when (this) {
    InsightSeverity.INFO -> (if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary) to "info"
    InsightSeverity.LOW -> AuroraColors.whimsy(isDark) to "low"
    InsightSeverity.MEDIUM -> InsightsColors.kpiNeutral to "medium"
    InsightSeverity.HIGH -> AuroraColors.ember(isDark) to "high"
    InsightSeverity.CRITICAL -> InsightsColors.kpiNegative to "critical"
}

@Composable
private fun ConfidenceChip(confidence: InsightConfidence) {
    val isDark = isSystemInDarkTheme()
    val whimsy = AuroraColors.whimsy(isDark)
    val dots = when (confidence) {
        InsightConfidence.LOW -> 1
        InsightConfidence.MEDIUM -> 2
        InsightConfidence.HIGH -> 3
    }
    val label = when (confidence) {
        InsightConfidence.LOW -> "low"
        InsightConfidence.MEDIUM -> "medium"
        InsightConfidence.HIGH -> "high"
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, whimsy.copy(alpha = 0.5f)),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Confidence $label" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        repeat(3) { index ->
            Box(
                modifier = Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (index < dots) whimsy else whimsy.copy(alpha = 0.2f)),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CitationChipRow(
    citations: List<InsightCitation>,
    onTap: (InsightCitation) -> Unit,
) {
    val visible = citations.take(6)
    val overflow = citations.size - visible.size
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        visible.forEach { citation ->
            CitationChip(citation = citation, onTap = onTap)
        }
        if (overflow > 0) {
            Text(
                text = "…+$overflow",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .semantics { contentDescription = "$overflow more citations" },
            )
        }
    }
}

@Composable
private fun CitationChip(
    citation: InsightCitation,
    onTap: (InsightCitation) -> Unit,
) {
    val provider = citationProvider(citation)
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .clickable { onTap(citation) }
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Citation ${citation.label}" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (provider != null) {
            ProviderLogo(
                provider = provider,
                size = 12.dp,
            )
        }
        Text(
            text = citation.label,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

@Composable
private fun ActionStripe(text: String) {
    Text(
        text = "→ $text",
        style = AuroraType.body.copy(fontWeight = FontWeight.Medium),
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "Recommended action: $text" }
            .padding(top = 2.dp),
    )
}

// ─── Reduce motion ────────────────────────────────────────────────────────

@Composable
private fun rememberReduceMotion(): Boolean {
    val auroraReduce = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val accessibilityReduce = remember(context) {
        runCatching {
            val am = context.getSystemService(AccessibilityManager::class.java)
            am?.isEnabled == true && am.isTouchExplorationEnabled
        }.getOrDefault(false)
    }
    return auroraReduce || accessibilityReduce
}

// ─── Strings & test tags ──────────────────────────────────────────────────

private const val EYEBROW = "INTELLIGENCE BRIEF"
private const val EYEBROW_DESCRIPTION = "Intelligence Brief"

internal const val SECTION_FINDINGS_TITLE = "TOP FINDINGS"
internal const val SECTION_MISSIONS_TITLE = "MISSION BOARD"
internal const val SECTION_ANOMALIES_TITLE = "ANOMALY ATLAS"
internal const val SECTION_RECOMMENDATIONS_TITLE = "RECOMMENDATIONS"
internal const val SECTION_GENERATED_TITLE = "GENERATED VIEWS"
internal const val SECTION_FOLLOWUPS_TITLE = "FOLLOW-UP QUESTIONS"

internal const val SECTION_TAG_HERO = "section-hero"
internal const val SECTION_TAG_FINDINGS = "section-findings"
internal const val SECTION_TAG_MISSIONS = "section-missions"
internal const val SECTION_TAG_ANOMALIES = "section-anomalies"
internal const val SECTION_TAG_RECOMMENDATIONS = "section-recommendations"
internal const val SECTION_TAG_GENERATED = "section-generated"
internal const val SECTION_TAG_FOLLOWUPS = "section-followups"
internal const val SECTION_TAG_AUDIT = "section-audit"

/** Em-space between follow-up question segments. */
private const val SEPARATOR = "\u2003"

// ─── Formatting helpers ───────────────────────────────────────────────────

/**
 * Shared formatting helpers — exposed so tests and the audit screen render
 * the same chip labels as the brief itself.
 */
object IntelligenceBriefFormatting {
    fun windowLabel(window: InsightTimeWindow): String = when (window) {
        InsightTimeWindow.Today -> "Today"
        InsightTimeWindow.Last24h -> "Last 24 hours"
        InsightTimeWindow.Last7d -> "Last 7 days"
        InsightTimeWindow.Last30d -> "Last 30 days"
        InsightTimeWindow.Last90d -> "Last 90 days"
        InsightTimeWindow.Last365d -> "Last 365 days"
        InsightTimeWindow.AllTime -> "All time"
        is InsightTimeWindow.Custom -> "${window.start} – ${window.end}"
    }

    fun budgetLabel(budget: InsightContextBudgetReport): String {
        val kb = (budget.encodedBytes / 1024).coerceAtLeast(1)
        val tokens = budget.estimatedPromptTokens
        val base = "~$kb KB · ~$tokens tokens"
        return if (budget.truncatedDataSources.isEmpty()) base else "$base · trimmed"
    }

    fun tokenUsageLabel(usage: InsightTokenUsage, cost: Double?): String {
        val total = usage.totalTokens
        return if (cost != null) "$total tokens · $%.4f".format(cost) else "$total tokens"
    }

    fun auditFooter(result: InsightAnalysisResult): String {
        val auditPrefix = result.auditID?.let { "Audit ${it.take(8)}" } ?: "Local run"
        val hash = result.resultHash.take(8)
        return "$auditPrefix · result $hash · ${result.modelTag.egressTier.displayLabel}"
    }
}
