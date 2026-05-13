package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTheme as CanvasTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Compose mirror of the shared SwiftUI [IntelligenceBriefView].
 *
 * Same story arc:
 *  1. Hero card with executive summary + model + budget + usage badges
 *  2. Findings (severity + confidence + evidence chips + action stripe)
 *  3. Anomalies (horizontal scroll of score-ranked chips)
 *  4. Recommendations (action card + impact)
 *  5. Generated widgets (rendered through [InsightWidgetRenderer]) with a pin
 *     action
 *  6. Follow-up question chips
 *  7. Audit footer
 *
 * The view is stateless on purpose — callers own the analysis result and the
 * callbacks. iPhone/iPad/tablet portrait/landscape are all the same surface;
 * the only thing that changes is the parent layout that hosts this screen.
 */
@Composable
fun IntelligenceBriefScreen(
    result: InsightAnalysisResult,
    modifier: Modifier = Modifier,
    onCitationTap: (InsightCitation) -> Unit = {},
    onFollowUpTap: (InsightFollowUpQuestion) -> Unit = {},
    onPinWidget: (InsightGeneratedWidget) -> Unit = {},
    onConfigureModel: (() -> Unit)? = null,
    onShowAudit: (() -> Unit)? = null,
    theme: CanvasTheme = CanvasTheme.AURORA,
) {
    val accents = InsightsColors.accentsFor(theme)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(AuroraSpacing.md.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        HeroCard(result = result, accents = accents, onConfigureModel = onConfigureModel)

        if (result.findings.isNotEmpty()) {
            SectionHeader(title = "Top findings", icon = Icons.Filled.AutoAwesome)
            result.findings.forEach { finding ->
                FindingCard(finding = finding, onCitationTap = onCitationTap)
            }
        }

        if (result.anomalies.isNotEmpty()) {
            SectionHeader(title = "Anomalies", icon = Icons.Filled.Warning)
            AnomalyRow(anomalies = result.anomalies, onCitationTap = onCitationTap)
        }

        if (result.recommendations.isNotEmpty()) {
            SectionHeader(title = "Recommendations", icon = Icons.Filled.Lightbulb)
            result.recommendations.forEach { rec ->
                RecommendationCard(recommendation = rec, onCitationTap = onCitationTap)
            }
        }

        if (result.generatedWidgets.isNotEmpty()) {
            SectionHeader(title = "Generated views", icon = Icons.Filled.Inventory2)
            result.generatedWidgets.forEach { generated ->
                GeneratedWidgetRow(
                    generated = generated,
                    onPin = onPinWidget,
                    onCitationTap = onCitationTap,
                    theme = theme,
                )
            }
        }

        if (result.followUpQuestions.isNotEmpty()) {
            SectionHeader(title = "Follow-up questions", icon = Icons.Filled.QuestionAnswer)
            FollowUpChips(questions = result.followUpQuestions, onTap = onFollowUpTap)
        }

        AuditFooter(result = result, onShowAudit = onShowAudit)
    }
}

// ─── Hero ─────────────────────────────────────────────────────────────────

@Composable
private fun HeroCard(
    result: InsightAnalysisResult,
    accents: List<Color>,
    onConfigureModel: (() -> Unit)?,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            modifier = Modifier.padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = accents.firstOrNull() ?: AuroraColors.ember,
                    modifier = Modifier.size(26.dp),
                )
                Spacer(Modifier.width(AuroraSpacing.sm.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Intelligence Brief",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = windowLabel(result.timeWindow),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (onConfigureModel != null) {
                    TextButton(onClick = onConfigureModel) { Text("Model") }
                }
            }
            Text(
                text = result.executiveSummary,
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
            ) {
                ModelChip(modelTag = result.modelTag)
                BudgetChip(budget = result.contextBudget)
                result.tokenUsage?.let { TokenUsageChip(usage = it, costUSD = result.estimatedCostUSD) }
            }
        }
    }
}

// ─── Section header ───────────────────────────────────────────────────────

@Composable
private fun SectionHeader(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

// ─── Finding ──────────────────────────────────────────────────────────────

@Composable
private fun FindingCard(finding: InsightFinding, onCitationTap: (InsightCitation) -> Unit) {
    SurfaceCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SeverityChip(severity = finding.severity)
                ConfidenceChip(confidence = finding.confidence)
            }
            Text(text = finding.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(
                text = finding.whyItMatters,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (finding.evidence.isNotEmpty()) {
                CitationChipRow(citations = finding.evidence, onTap = onCitationTap)
            }
            if (finding.recommendedAction.isNotBlank()) {
                ActionStripe(text = finding.recommendedAction)
            }
        }
    }
}

// ─── Anomaly row ──────────────────────────────────────────────────────────

@Composable
private fun AnomalyRow(anomalies: List<InsightAnomaly>, onCitationTap: (InsightCitation) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        anomalies.forEach { anomaly ->
            AnomalyChip(anomaly = anomaly, onCitationTap = onCitationTap)
        }
    }
}

@Composable
private fun AnomalyChip(anomaly: InsightAnomaly, onCitationTap: (InsightCitation) -> Unit) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier
            .width(220.dp)
            .clickable {
                anomaly.evidence.firstOrNull()?.let { onCitationTap(it) }
            },
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Warning,
                    contentDescription = null,
                    tint = InsightsColors.kpiNeutral,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text(text = anomaly.title, style = MaterialTheme.typography.labelLarge, maxLines = 2)
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = anomaly.detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
            )
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(text = "z %.1f".format(anomaly.score), style = MaterialTheme.typography.labelSmall)
                Spacer(Modifier.width(6.dp))
                ConfidenceChip(confidence = anomaly.confidence)
            }
        }
    }
}

// ─── Recommendation ──────────────────────────────────────────────────────

@Composable
private fun RecommendationCard(
    recommendation: InsightRecommendation,
    onCitationTap: (InsightCitation) -> Unit,
) {
    SurfaceCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Lightbulb,
                    contentDescription = null,
                    tint = AuroraColors.whimsy,
                    modifier = Modifier.size(14.dp),
                )
                SeverityChip(severity = recommendation.severity)
                ConfidenceChip(confidence = recommendation.confidence)
            }
            Text(text = recommendation.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(
                text = recommendation.rationale,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            ActionStripe(text = recommendation.recommendedAction)
            recommendation.estimatedImpact?.takeIf { it.isNotBlank() }?.let { impact ->
                Text(
                    text = "↑ $impact",
                    style = MaterialTheme.typography.labelMedium,
                    color = AuroraColors.success,
                )
            }
            if (recommendation.evidence.isNotEmpty()) {
                CitationChipRow(citations = recommendation.evidence, onTap = onCitationTap)
            }
        }
    }
}

// ─── Generated widget row ────────────────────────────────────────────────

@Composable
private fun GeneratedWidgetRow(
    generated: InsightGeneratedWidget,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
    theme: CanvasTheme,
) {
    SurfaceCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = generated.widget.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { onPin(generated) }) {
                    Icon(Icons.Filled.PushPin, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Pin")
                }
            }
            InsightWidgetRenderer(
                widget = generated.widget,
                onCitationTap = onCitationTap,
                theme = theme,
            )
            if (generated.citations.isNotEmpty()) {
                CitationChipRow(citations = generated.citations, onTap = onCitationTap)
            }
            if (generated.reason.isNotBlank()) {
                Text(
                    text = generated.reason,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

// ─── Follow-up chips ──────────────────────────────────────────────────────

@Composable
private fun FollowUpChips(
    questions: List<InsightFollowUpQuestion>,
    onTap: (InsightFollowUpQuestion) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        questions.forEach { question ->
            Surface(
                modifier = Modifier.clickable { onTap(question) },
                shape = RoundedCornerShape(20.dp),
                color = AuroraColors.purple.copy(alpha = 0.12f),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.QuestionAnswer,
                        contentDescription = null,
                        tint = AuroraColors.purple,
                        modifier = Modifier.size(12.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = question.question,
                        style = MaterialTheme.typography.labelMedium,
                        color = AuroraColors.purple,
                        maxLines = 2,
                    )
                }
            }
        }
    }
}

// ─── Audit footer ─────────────────────────────────────────────────────────

@Composable
private fun AuditFooter(result: InsightAnalysisResult, onShowAudit: (() -> Unit)?) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = IntelligenceBriefFormatting.auditFooter(result),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
            maxLines = 2,
        )
        if (onShowAudit != null) {
            TextButton(onClick = onShowAudit) { Text("Audit log") }
        }
    }
}

// ─── Chips ────────────────────────────────────────────────────────────────

@Composable
private fun ModelChip(modelTag: InsightModelTag) {
    Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = modelTag.displayName, style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.width(4.dp))
            Text(
                text = "· ${modelTag.egressTier.displayLabel}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun BudgetChip(budget: InsightContextBudgetReport) {
    Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Inventory2, contentDescription = null, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(4.dp))
            Text(IntelligenceBriefFormatting.budgetLabel(budget), style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun TokenUsageChip(usage: InsightTokenUsage, costUSD: Double?) {
    Surface(shape = RoundedCornerShape(50), color = AuroraColors.success.copy(alpha = 0.12f)) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Bolt, contentDescription = null, tint = AuroraColors.success, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(4.dp))
            Text(
                text = IntelligenceBriefFormatting.tokenUsageLabel(usage, costUSD),
                style = MaterialTheme.typography.labelSmall,
                color = AuroraColors.success,
            )
        }
    }
}

@Composable
private fun SeverityChip(severity: InsightSeverity) {
    val (color, label) = when (severity) {
        InsightSeverity.INFO -> MaterialTheme.colorScheme.onSurfaceVariant to "info"
        InsightSeverity.LOW -> AuroraColors.purple to "low"
        InsightSeverity.MEDIUM -> InsightsColors.kpiNeutral to "medium"
        InsightSeverity.HIGH -> AuroraColors.ember to "high"
        InsightSeverity.CRITICAL -> InsightsColors.kpiNegative to "critical"
    }
    Surface(shape = RoundedCornerShape(50), color = color.copy(alpha = 0.12f)) {
        Text(
            text = label.uppercase(),
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = color,
        )
    }
}

@Composable
private fun ConfidenceChip(confidence: InsightConfidence) {
    val dots = when (confidence) {
        InsightConfidence.LOW -> 1
        InsightConfidence.MEDIUM -> 2
        InsightConfidence.HIGH -> 3
    }
    Surface(shape = RoundedCornerShape(50), color = AuroraColors.purple.copy(alpha = 0.10f)) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(dots) { _ ->
                Spacer(
                    modifier = Modifier
                        .size(5.dp)
                        .clip(CircleShape)
                        .background(AuroraColors.purple),
                )
                Spacer(Modifier.width(2.dp))
            }
        }
    }
}

@Composable
private fun CitationChipRow(citations: List<InsightCitation>, onTap: (InsightCitation) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        citations.take(6).forEach { citation ->
            Surface(
                modifier = Modifier.clickable { onTap(citation) },
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
            ) {
                Text(
                    text = citation.label,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun ActionStripe(text: String) {
    Surface(shape = RoundedCornerShape(8.dp), color = AuroraColors.purple.copy(alpha = 0.08f)) {
        Text(
            text = "→ $text",
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

// ─── Surface wrapper ──────────────────────────────────────────────────────

@Composable
private fun SurfaceCard(content: @Composable () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) { content() }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────

private fun windowLabel(window: InsightTimeWindow): String = when (window) {
    InsightTimeWindow.Today -> "Today"
    InsightTimeWindow.Last24h -> "Last 24 hours"
    InsightTimeWindow.Last7d -> "Last 7 days"
    InsightTimeWindow.Last30d -> "Last 30 days"
    InsightTimeWindow.Last90d -> "Last 90 days"
    InsightTimeWindow.Last365d -> "Last 365 days"
    InsightTimeWindow.AllTime -> "All time"
    is InsightTimeWindow.Custom -> "${window.start} – ${window.end}"
}

/**
 * Shared formatting helpers — exposed so tests and the audit screen can
 * render the same chip labels as the brief itself.
 */
object IntelligenceBriefFormatting {
    fun budgetLabel(budget: InsightContextBudgetReport): String {
        val kb = (budget.encodedBytes / 1024).coerceAtLeast(1)
        val tokens = budget.estimatedPromptTokens
        val base = "~${kb} KB · ~${tokens} tokens"
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
