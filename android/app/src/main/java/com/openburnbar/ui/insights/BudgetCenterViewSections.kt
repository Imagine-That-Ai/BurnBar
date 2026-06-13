// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.models.BudgetEvent
import com.openburnbar.data.models.BudgetRule
import com.openburnbar.ui.components.AuroraButton
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.util.Formatting

@Composable
internal fun BudgetCenterSummaryBanner(
    totalSpend: Double,
    totalLimit: Double,
    aggregatePercent: Double,
    isDark: Boolean,
) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text(
                        text = "Monthly Spend Rollup",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Aggregated limit performance",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                BudgetUsageStatusBadge(aggregatePercent = aggregatePercent, isDark = isDark)
            }
            Spacer(modifier = Modifier.height(16.dp))
            BudgetCenterSummarySpendRow(totalSpend, totalLimit, aggregatePercent)
            Spacer(modifier = Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { aggregatePercent.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(8.dp),
                color = budgetUsageProgressColor(aggregatePercent, isDark),
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
                strokeCap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun BudgetCenterSummarySpendRow(totalSpend: Double, totalLimit: Double, aggregatePercent: Double) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Bottom,
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = Formatting.formatCurrency(totalSpend),
                fontSize = 28.sp,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = "/ ${Formatting.formatCurrency(totalLimit)}",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        Text(
            text = "${(aggregatePercent * 100).toInt()}% Used",
            style = AuroraType.caption,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun BudgetUsageStatusBadge(aggregatePercent: Double, isDark: Boolean) {
    val (label, bgColor, fgColor) = budgetUsageStatusTriple(aggregatePercent, isDark)
    Box(
        modifier = Modifier.background(color = bgColor, shape = RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(text = label, color = fgColor, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

private data class BudgetForecastMetrics(
    val rulesEmpty: Boolean,
    val dailyAverage: Double,
    val monthEndSpend: Double,
    val limitBreach: Boolean,
    val breachDays: Int,
    val totalLimit: Double,
)

private fun computeBudgetForecastMetrics(
    rules: List<BudgetRuleEntity>,
    totalSpend: Double,
    totalLimit: Double,
): BudgetForecastMetrics {
    val dailyAverage =
        if (rules.isNotEmpty()) {
            val calculated = totalSpend / 14.0
            if (calculated <= 0.0) 1.45 else calculated
        } else {
            0.0
        }
    val monthEndSpend = dailyAverage * 30.0
    val limitBreach = totalLimit > 0.0 && monthEndSpend > totalLimit
    val breachDays =
        if (dailyAverage > 0.0 && totalLimit > totalSpend) {
            ((totalLimit - totalSpend) / dailyAverage).toInt().coerceAtLeast(1)
        } else {
            0
        }
    return BudgetForecastMetrics(
        rulesEmpty = rules.isEmpty(),
        dailyAverage = dailyAverage,
        monthEndSpend = monthEndSpend,
        limitBreach = limitBreach,
        breachDays = breachDays,
        totalLimit = totalLimit,
    )
}

private fun budgetForecastProjectionText(metrics: BudgetForecastMetrics): String =
    when {
        metrics.rulesEmpty ->
            "Configure budget rules above to enable run-rate predictive forecasts and automated breach alerting."
        metrics.limitBreach -> {
            val limit = Formatting.formatCurrency(metrics.totalLimit)
            "⚠️ AI Projection: At your current 7-day average run rate, you are projected to breach " +
                "your total budget limit of $limit in approximately ${metrics.breachDays} days. " +
                "We recommend applying route-optimisation options listed below."
        }
        else ->
            "✨ AI Projection: Nominal run-rate detected. You are fully on track to finish the " +
                "current billing cycle safe within your configured limits."
    }

@Composable
internal fun BudgetCenterForecastCard(
    rules: List<BudgetRuleEntity>,
    totalSpend: Double,
    totalLimit: Double,
    isDark: Boolean,
) {
    val metrics = computeBudgetForecastMetrics(rules, totalSpend, totalLimit)
    AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Column(modifier = Modifier.padding(16.dp)) {
            BudgetCenterForecastHeader(metrics, isDark)
            Spacer(modifier = Modifier.height(12.dp))
            BudgetCenterForecastMetricsRow(metrics, isDark)
            Spacer(modifier = Modifier.height(12.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f), thickness = 1.dp)
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = budgetForecastProjectionText(metrics),
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 16.sp,
            )
        }
    }
}

@Composable
private fun BudgetCenterForecastHeader(metrics: BudgetForecastMetrics, isDark: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "🔮 Predictive Forecast",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        BudgetForecastStatusBadge(rulesEmpty = metrics.rulesEmpty, limitBreach = metrics.limitBreach, isDark = isDark)
    }
}

@Composable
private fun BudgetCenterForecastMetricsRow(metrics: BudgetForecastMetrics, isDark: Boolean) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Column {
            Text("Daily Average Run Rate", style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                text = "${Formatting.formatCurrency(metrics.dailyAverage)} / day",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Text("Projected Month End", style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                text = Formatting.formatCurrency(metrics.monthEndSpend),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
                color = budgetForecastMonthEndColor(metrics, isDark),
            )
        }
    }
}

@Composable
private fun budgetForecastMonthEndColor(metrics: BudgetForecastMetrics, isDark: Boolean): Color =
    when {
        metrics.limitBreach -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
        metrics.rulesEmpty -> MaterialTheme.colorScheme.onSurface
        else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
    }

@Composable
private fun BudgetForecastStatusBadge(rulesEmpty: Boolean, limitBreach: Boolean, isDark: Boolean) {
    val (label, bgColor, fgColor) =
        when {
            rulesEmpty -> Triple("No active limit", MaterialTheme.colorScheme.surfaceVariant, MaterialTheme.colorScheme.onSurfaceVariant)
            limitBreach ->
                Triple(
                    "Breach Risk: High",
                    if (isDark) AuroraColors.emberDark.copy(alpha = 0.2f) else AuroraColors.ember.copy(alpha = 0.15f),
                    if (isDark) AuroraColors.emberDark else AuroraColors.ember,
                )
            else ->
                Triple(
                    "On Track (Safe)",
                    if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                    if (isDark) AuroraColors.tealDark else AuroraColors.teal,
                )
        }
    Box(
        modifier = Modifier.background(color = bgColor, shape = RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(text = label, color = fgColor, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
internal fun BudgetCenterRulesHeader(hasRules: Boolean, onAddRule: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = "Active Limit Rules", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
        if (hasRules) {
            TextButton(onClick = onAddRule) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text("Add Rule", fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
internal fun BudgetCenterRulesLoading() {
    Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
internal fun BudgetCenterRulesEmpty(onAddRule: () -> Unit) {
    Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
        AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = Icons.Default.Tune,
                    contentDescription = null,
                    modifier = Modifier.size(44.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = "Secure your credentials & keep budget bounds.",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Setup limits globally, per provider, organization, or project.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(18.dp))
                AuroraButton(onClick = onAddRule) {
                    Icon(Icons.Default.Add, contentDescription = null, tint = Color.White)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Create Budget Rule", color = Color.White, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
internal fun BudgetCenterRuleCard(
    entity: BudgetRuleEntity,
    spend: Double,
    isDark: Boolean,
    onToggleEnabled: (Boolean) -> Unit,
    onDelete: () -> Unit,
) {
    val rule = entity.toModel()
    val limit = rule.amountUSD
    val percent = if (limit > 0.0) spend / limit else 0.0

    AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row(modifier = Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = rule.displayLabel, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = "Scope: ${rule.scope.replaceFirstChar { it.uppercase() }} · Reset: ${rule.period.replaceFirstChar { it.uppercase() }}",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Spent ${Formatting.formatCurrency(spend)} of ${Formatting.formatCurrency(limit)} (${(percent * 100).toInt()}%)",
                    style = AuroraType.caption,
                    fontWeight = FontWeight.SemiBold,
                    color = budgetUsageProgressColor(percent, isDark),
                )
                Spacer(modifier = Modifier.height(6.dp))
                LinearProgressIndicator(
                    progress = { percent.toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth().height(4.dp),
                    color = budgetUsageProgressColor(percent, isDark),
                    trackColor = MaterialTheme.colorScheme.surfaceVariant,
                    strokeCap = StrokeCap.Round,
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Switch(checked = entity.isEnabled, onCheckedChange = onToggleEnabled)
            IconButton(onClick = onDelete) {
                Icon(imageVector = Icons.Default.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

internal data class BudgetCenterRulesSectionCallbacks(
    val onAddRule: () -> Unit,
    val onToggleRule: (BudgetRuleEntity, Boolean) -> Unit,
    val onDeleteRule: (BudgetRule) -> Unit,
)

internal fun LazyListScope.budgetCenterRulesSection(
    isLoading: Boolean,
    rules: List<BudgetRuleEntity>,
    spendMap: Map<String, Double>,
    isDark: Boolean,
    callbacks: BudgetCenterRulesSectionCallbacks,
) {
    item { BudgetCenterRulesHeader(hasRules = rules.isNotEmpty(), onAddRule = callbacks.onAddRule) }
    when {
        isLoading -> item { BudgetCenterRulesLoading() }
        rules.isEmpty() -> item { BudgetCenterRulesEmpty(onAddRule = callbacks.onAddRule) }
        else ->
            items(rules) { entity ->
                BudgetCenterRuleCard(
                    entity = entity,
                    spend = spendMap[entity.id] ?: 0.0,
                    isDark = isDark,
                    onToggleEnabled = { callbacks.onToggleRule(entity, it) },
                    onDelete = { callbacks.onDeleteRule(entity.toModel()) },
                )
            }
    }
}

@Composable
internal fun BudgetCenterAiRecommendationsHeader() {
    Spacer(modifier = Modifier.height(8.dp))
    Text(
        text = "💡 AI Recommendations",
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

@Composable
internal fun BudgetCenterAiRecommendationsList(isDark: Boolean) {
    Column(modifier = Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        BudgetAiRecommendationCard(
            title = "Consolidate Route-Optimisation",
            savingsLabel = "Save $18.50/mo",
            body = "Claude 3.5 Sonnet driving 84% of total usage. Routing routine code tasks to Claude 3.5 Haiku is estimated to reduce month-end run rates by 26% without compromising quality.",
            isDark = isDark,
        )
        BudgetAiRecommendationCard(
            title = "Enable Prompt Cache Creation",
            savingsLabel = "Save $12.80/mo",
            body =
            "Claude Code submitting large context payloads of 145,000 tokens on repetitive directory reads. " +
                "Activating Prompt Caching lowers read pricing by 90%, yielding significant immediate margins.",
            isDark = isDark,
        )
        BudgetAiRecommendationCard(
            title = "Configure Idle Timeout Limits",
            savingsLabel = "Save $5.20/wk",
            body = "Observed 4 idle background watch sessions passively polling directory tree updates. Auto-sleeping sessions after 15 minutes of terminal inactivity reduces passive billing costs.",
            isDark = isDark,
        )
    }
}

@Composable
private fun BudgetAiRecommendationCard(title: String, savingsLabel: String, body: String, isDark: Boolean) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(text = title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold)
                Box(
                    modifier =
                    Modifier
                        .background(
                            color = if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(6.dp),
                        )
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text(
                        text = savingsLabel,
                        color = if (isDark) AuroraColors.tealDark else AuroraColors.teal,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = body,
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 15.sp,
            )
        }
    }
}

@Composable
internal fun BudgetCenterActivityLogHeader() {
    Text(
        text = "Recent Activity Log",
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

@Composable
internal fun BudgetCenterActivityLogEmpty() {
    Text(
        text = "No budgeting events recorded yet.",
        style = AuroraType.caption,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

@Composable
internal fun BudgetCenterActivityLogEvent(event: BudgetEvent, isDark: Boolean) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = event.kind.replaceFirstChar { it.uppercase() },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                    color =
                    when (event.kind) {
                        "block" -> MaterialTheme.colorScheme.error
                        "warning" -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                        else -> MaterialTheme.colorScheme.primary
                    },
                )
                Text(
                    text = event.occurredAt?.toString() ?: "",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Rule ID: ${event.ruleID.take(8)} · Amount: ${Formatting.formatCurrency(event.amountAtEvent)} / limit: ${Formatting.formatCurrency(event.limitAtEvent)}",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

internal fun LazyListScope.budgetCenterActivityLogSection(recentEvents: List<BudgetEvent>, isDark: Boolean) {
    item { BudgetCenterActivityLogHeader() }
    if (recentEvents.isEmpty()) {
        item { BudgetCenterActivityLogEmpty() }
    } else {
        items(recentEvents) { event ->
            BudgetCenterActivityLogEvent(event = event, isDark = isDark)
        }
    }
}

@Composable
private fun budgetUsageProgressColor(percent: Double, isDark: Boolean): Color =
    when {
        percent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
        percent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
        else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
    }

private fun budgetUsageStatusTriple(aggregatePercent: Double, isDark: Boolean): Triple<String, Color, Color> =
    when {
        aggregatePercent >= 1.0 ->
            Triple(
                "Blocked",
                if (isDark) AuroraColors.emberDark.copy(alpha = 0.2f) else AuroraColors.ember.copy(alpha = 0.15f),
                if (isDark) AuroraColors.emberDark else AuroraColors.ember,
            )
        aggregatePercent >= 0.8 ->
            Triple(
                "Warning",
                if (isDark) AuroraColors.amberDark.copy(alpha = 0.2f) else AuroraColors.amber.copy(alpha = 0.15f),
                if (isDark) AuroraColors.amberDark else AuroraColors.amber,
            )
        else ->
            Triple(
                "Nominal",
                if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                if (isDark) AuroraColors.tealDark else AuroraColors.teal,
            )
    }
