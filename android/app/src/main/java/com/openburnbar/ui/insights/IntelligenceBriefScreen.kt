// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

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
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme as CanvasTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.util.Formatting
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
 */
private data class IntelligenceBriefCallbacks(
    val onCitationTap: (InsightCitation) -> Unit,
    val onFollowUpTap: (InsightFollowUpQuestion) -> Unit,
    val onMissionLaunchTap: (MissionLaunchAction, MissionLaunchOptions) -> Unit,
    val onPinWidget: (InsightGeneratedWidget) -> Unit,
    val onConfigureModel: (() -> Unit)?,
    val onUpgradeToPro: (() -> Unit)?,
    val onShowAudit: (() -> Unit)?,
)

private data class IntelligenceBriefSectionEnv(
    val result: InsightAnalysisResult,
    val theme: CanvasTheme,
    val isDark: Boolean,
    val reduceMotion: Boolean,
    val visibility: SnapshotStateList<Boolean>,
    val expandedMissionID: String?,
    val onExpandedMissionIDChange: (String?) -> Unit,
    val callbacks: IntelligenceBriefCallbacks,
)

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
    val visibility = rememberSectionVisibility(reduceMotion)
    var expandedMissionID by remember(result.id) { mutableStateOf<String?>(null) }

    val callbacks =
        IntelligenceBriefCallbacks(
            onCitationTap = onCitationTap,
            onFollowUpTap = onFollowUpTap,
            onMissionLaunchTap = onMissionLaunchTap,
            onPinWidget = onPinWidget,
            onConfigureModel = onConfigureModel,
            onUpgradeToPro = onUpgradeToPro,
            onShowAudit = onShowAudit,
        )
    val sectionEnv =
        IntelligenceBriefSectionEnv(
            result = result,
            theme = theme,
            isDark = isDark,
            reduceMotion = reduceMotion,
            visibility = visibility,
            expandedMissionID = expandedMissionID,
            onExpandedMissionIDChange = { expandedMissionID = it },
            callbacks = callbacks,
        )

    Column(
        modifier =
        modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xl.dp),
    ) {
        BriefOpeningSections(env = sectionEnv)
        BriefAnalysisSections(env = sectionEnv)
        BriefClosingSections(env = sectionEnv)
    }
}

@Composable
private fun BriefOpeningSections(env: IntelligenceBriefSectionEnv) {
    AnimatedSection(visible = env.visibility[0], reduceMotion = env.reduceMotion) {
        HeroSection(
            result = env.result,
            isDark = env.isDark,
            reduceMotion = env.reduceMotion,
            onConfigureModel = env.callbacks.onConfigureModel,
            onUpgradeToPro = env.callbacks.onUpgradeToPro,
            onCitationTap = env.callbacks.onCitationTap,
        )
    }

    AnimatedSection(visible = env.visibility[1], reduceMotion = env.reduceMotion) {
        MissionLaunchpad(onSelect = env.callbacks.onMissionLaunchTap)
    }

    if (env.result.findings.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[2], reduceMotion = env.reduceMotion) {
            FindingsSection(findings = env.result.findings, onCitationTap = env.callbacks.onCitationTap)
        }
    }

    if (env.result.missionCandidates.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[3], reduceMotion = env.reduceMotion) {
            MissionBoardSection(
                missions = env.result.missionCandidates,
                expandedMissionID = env.expandedMissionID,
                onToggle = { missionID ->
                    env.onExpandedMissionIDChange(if (env.expandedMissionID == missionID) null else missionID)
                },
                onLaunch = { mission ->
                    env.callbacks.onMissionLaunchTap(mission.launchAction(), defaultCandidateMissionOptions(mission))
                },
                onCitationTap = env.callbacks.onCitationTap,
            )
        }
    }
}

@Composable
private fun BriefAnalysisSections(env: IntelligenceBriefSectionEnv) {
    if (env.result.anomalies.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[4], reduceMotion = env.reduceMotion) {
            AnomalyAtlasSection(anomalies = env.result.anomalies, onCitationTap = env.callbacks.onCitationTap)
        }
    }

    if (env.result.recommendations.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[5], reduceMotion = env.reduceMotion) {
            RecommendationsSection(
                recommendations = env.result.recommendations,
                isDark = env.isDark,
                onCitationTap = env.callbacks.onCitationTap,
            )
        }
    }

    if (env.result.generatedWidgets.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[6], reduceMotion = env.reduceMotion) {
            GeneratedViewsSection(
                generated = env.result.generatedWidgets,
                figureStart = 1,
                theme = env.theme,
                onPin = env.callbacks.onPinWidget,
                onCitationTap = env.callbacks.onCitationTap,
            )
        }
    }
}

@Composable
private fun BriefClosingSections(env: IntelligenceBriefSectionEnv) {
    if (env.result.followUpQuestions.isNotEmpty()) {
        AnimatedSection(visible = env.visibility[7], reduceMotion = env.reduceMotion) {
            FollowUpSection(
                questions = env.result.followUpQuestions,
                isDark = env.isDark,
                onTap = env.callbacks.onFollowUpTap,
            )
        }
    }

    AnimatedSection(visible = env.visibility[8], reduceMotion = env.reduceMotion) {
        AuditFooterSection(
            result = env.result,
            isDark = env.isDark,
            onShowAudit = env.callbacks.onShowAudit,
        )
    }
}

private fun defaultCandidateMissionOptions(mission: com.openburnbar.data.insights.InsightMissionCandidate): MissionLaunchOptions =
    MissionLaunchOptions(
        requestedRuntime = MissionRuntimeTarget.AUTO.firestoreValue,
        targetProject = mission.projectDisplayName ?: mission.projectID,
        depth = MissionDepth.STANDARD.firestoreValue,
        approvalMode = MissionApprovalMode.EXISTING.firestoreValue,
        commandsAllowed = false,
        fileEditsAllowed = false,
    )

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
private fun AnimatedSection(visible: Boolean, reduceMotion: Boolean, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    if (reduceMotion) {
        content()
        return
    }
    AnimatedVisibility(
        visible = visible,
        enter =
        slideInVertically(
            animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f),
            initialOffsetY = { with(density) { 8.dp.roundToPx() } },
        ) + fadeIn(animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f)),
    ) {
        content()
    }
}

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
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_HERO),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        HeroEyebrowBlock(result = result)
        HeroSummaryRow(result = result)
        result.briefingAnswer?.let { answer ->
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
        MercuryHairline(isDark = isDark, reduceMotion = reduceMotion, shimmer = true)
    }
}

@Composable
private fun HeroEyebrowBlock(result: InsightAnalysisResult) {
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
}

@Composable
private fun HeroSummaryRow(result: InsightAnalysisResult) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        heroLeadProvider(result)?.let { leadProvider ->
            ProviderLogo(
                provider = leadProvider,
                size = 44.dp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        Text(
            text = result.executiveSummary,
            style =
            AuroraType.title.copy(
                fontFamily = FontFamily.SansSerif,
                fontSize = 22.sp,
                lineHeight = 30.8.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.semantics { heading() },
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
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.68f))
            .border(BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(8.dp))
            .padding(AuroraSpacing.md.dp)
            .animateContentSize(),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Text(
            text = answer.answer,
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurface,
        )
        AnswerPanelBullets(bullets = answer.bullets)
        if (answer.citations.isNotEmpty()) {
            CitationChipRow(citations = answer.citations, onTap = onCitationTap)
        }
        AnswerPanelCtas(
            answer = answer,
            onConfigureModel = onConfigureModel,
            onUpgradeToPro = onUpgradeToPro,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AnswerPanelBullets(bullets: List<String>) {
    if (bullets.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        bullets.take(4).forEach { bullet ->
            Text(
                text = bullet,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier =
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .border(BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(999.dp))
                    .padding(horizontal = AuroraSpacing.sm.dp, vertical = 3.dp),
            )
        }
    }
}

@Composable
private fun AnswerPanelCtas(
    answer: InsightBriefingAnswer,
    onConfigureModel: (() -> Unit)?,
    onUpgradeToPro: (() -> Unit)?,
) {
    val showUpgradeToProCTA =
        onUpgradeToPro != null &&
            answer.modelDisplayName == InsightBriefingAnswer.SUBSCRIPTION_REQUIRED_DISPLAY_NAME
    val showConnectModelCTA =
        onConfigureModel != null && !showUpgradeToProCTA &&
            when (answer.source) {
                InsightBriefingAnswer.Source.LOCAL_RULES ->
                    answer.modelDisplayName.contains("no LLM configured", ignoreCase = true)
                InsightBriefingAnswer.Source.HOSTED_FALLBACK -> true
                InsightBriefingAnswer.Source.MODEL_GATEWAY -> false
            }

    when {
        showUpgradeToProCTA -> onUpgradeToPro?.let { upgradeAction ->
            Button(
                onClick = upgradeAction,
                colors =
                ButtonDefaults.buttonColors(
                    containerColor = InsightsColors.kpiPositive.copy(alpha = 0.20f),
                    contentColor = InsightsColors.kpiPositive,
                ),
                modifier =
                Modifier
                    .padding(top = 2.dp)
                    .semantics {
                        contentDescription =
                            "Upgrade to BurnBar Pro. Unlocks the BurnBar-hosted Intelligence Brief AI answers. Subscription required."
                    },
            ) {
                Text(
                    text = "Upgrade to BurnBar Pro",
                    style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                )
            }
        }
        showConnectModelCTA -> onConfigureModel?.let { configureModel ->
            Button(
                onClick = configureModel,
                colors =
                ButtonDefaults.buttonColors(
                    containerColor = InsightsColors.kpiPositive.copy(alpha = 0.16f),
                    contentColor = InsightsColors.kpiPositive,
                ),
                modifier =
                Modifier
                    .padding(top = 2.dp)
                    .semantics {
                        contentDescription =
                            "Connect a model. Opens the Insights model picker so a connected gateway can author the reply."
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

private fun heroLeadProvider(result: InsightAnalysisResult): AgentProvider? {
    val candidates = result.findings.firstOrNull()?.evidence.orEmpty() + result.citations
    for (citation in candidates) {
        val kind = citation.kind
        if (kind is InsightCitation.Kind.Agent) {
            AgentProvider.fromKey(kind.provider)?.let { return it }
        }
    }
    return null
}

private fun answerEyebrow(answer: InsightBriefingAnswer): String = when {
    answer.isFallback -> "Answered locally after LLM fallback"
    answer.source == InsightBriefingAnswer.Source.MODEL_GATEWAY -> "Answered by ${answer.modelDisplayName}"
    answer.source == InsightBriefingAnswer.Source.HOSTED_FALLBACK ->
        "Answered by ${answer.modelDisplayName} · hosted fallback"
    else -> "Data summary · ${answer.modelDisplayName}"
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
    val parts =
        buildList {
            add(modelTag.displayName)
            add(modelTag.egressTier.displayLabel)
            add(IntelligenceBriefFormatting.budgetLabel(budget))
            if (tokenUsage != null) add(IntelligenceBriefFormatting.tokenUsageLabel(tokenUsage, costUSD))
        }
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

@Composable
private fun rememberReduceMotion(): Boolean {
    val auroraReduce = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val accessibilityReduce =
        remember(context) {
            runCatching {
                val am = context.getSystemService(AccessibilityManager::class.java)
                am?.isEnabled == true && am.isTouchExplorationEnabled
            }.getOrDefault(false)
        }
    return auroraReduce || accessibilityReduce
}

private const val EYEBROW = "INTELLIGENCE BRIEF"
private const val EYEBROW_DESCRIPTION = "Intelligence Brief"

internal const val SECTION_TAG_HERO = "section-hero"

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
        return if (cost != null) "$total tokens · ${Formatting.formatPreciseCurrency(cost)}" else "$total tokens"
    }

    fun auditFooter(result: InsightAnalysisResult): String {
        val auditPrefix = result.auditID?.let { "Audit ${it.take(8)}" } ?: "Local run"
        val hash = result.resultHash.take(8)
        return "$auditPrefix · result $hash · ${result.modelTag.egressTier.displayLabel}"
    }
}
