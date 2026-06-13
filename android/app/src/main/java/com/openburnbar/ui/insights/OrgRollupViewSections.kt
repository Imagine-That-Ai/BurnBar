// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import android.content.Context
import android.content.SharedPreferences
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.BudgetDatabaseAccess
import com.openburnbar.data.models.OrgRollupRow
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.util.Formatting
import java.util.Calendar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun orgRollupSharedPrefs(context: Context): SharedPreferences =
    context.getSharedPreferences("burnbar_enterprise", Context.MODE_PRIVATE)

internal fun orgRollupWindowStartMs(period: String): Long {
    if (period == "allTime") return 0L
    val calendar = Calendar.getInstance()
    calendar.set(Calendar.HOUR_OF_DAY, 0)
    calendar.set(Calendar.MINUTE, 0)
    calendar.set(Calendar.SECOND, 0)
    calendar.set(Calendar.MILLISECOND, 0)
    return when (period) {
        "day" -> calendar.timeInMillis
        "week" -> {
            calendar.set(Calendar.DAY_OF_WEEK, calendar.firstDayOfWeek)
            calendar.timeInMillis
        }
        "month" -> {
            calendar.set(Calendar.DAY_OF_MONTH, 1)
            calendar.timeInMillis
        }
        else -> 0L
    }
}

internal suspend fun fetchOrgRollupRows(
    dao: BudgetDatabaseAccess,
    segment: String,
    period: String,
): List<OrgRollupRow> {
    val windowStart = orgRollupWindowStartMs(period)
    return withContext(Dispatchers.IO) {
        when (segment) {
            "user" -> dao.orgRollupByUser(windowStart, 50)
            "project" -> dao.orgRollupByProject(windowStart, 50)
            "credential" -> dao.orgRollupByCredential(windowStart, 50)
            "provider" -> dao.orgRollupByProvider(windowStart, 50)
            else -> emptyList()
        }
    }
}

@Composable
internal fun OrgRollupHeader(isDark: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(
            imageVector = Icons.Default.Business,
            contentDescription = "Enterprise Rollup",
            tint = if (isDark) AuroraColors.purpleDark else AuroraColors.purple,
            modifier = Modifier.size(28.dp),
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column {
            Text(
                text = "ENTERPRISE",
                style = AuroraType.caption,
                fontWeight = FontWeight.Bold,
                color = if (isDark) AuroraColors.purpleDark else AuroraColors.purple,
            )
            Text(
                text = "Cross-Seat Spend Rollup",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
internal fun OrgRollupLockedGate(
    sharedPrefs: SharedPreferences,
    onEnable: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        AuroraGlassCard(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.lg.dp),
        ) {
            Column(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(AuroraSpacing.lg.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.Lock,
                    contentDescription = "Enterprise Gated",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                Text(
                    text = "Enterprise View Disabled",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                Text(
                    text = "Enable enterpriseOrgViewEnabled settings to aggregate cross-device token spends, cost metrics, and device seat counts.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                Button(
                    onClick = {
                        onEnable()
                        sharedPrefs.edit().putBoolean("enterpriseOrgViewEnabled", true).apply()
                    },
                ) {
                    Text("Enable Dashboard")
                }
            }
        }
    }
}

@Composable
internal fun OrgRollupFilterBar(
    selectedSegment: String,
    selectedPeriod: String,
    onSegmentSelected: (String) -> Unit,
    onPeriodSelected: (String) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf("user" to "User", "project" to "Proj", "credential" to "Cred", "provider" to "Prov").forEach { (segmentKey, label) ->
                FilterChip(
                    selected = selectedSegment == segmentKey,
                    onClick = { onSegmentSelected(segmentKey) },
                    label = { Text(label, fontSize = 10.sp) },
                    modifier = Modifier.height(28.dp),
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf("day" to "D", "week" to "W", "month" to "M", "allTime" to "All").forEach { (periodKey, label) ->
                FilterChip(
                    selected = selectedPeriod == periodKey,
                    onClick = { onPeriodSelected(periodKey) },
                    label = { Text(label, fontSize = 10.sp) },
                    modifier = Modifier.height(28.dp),
                )
            }
        }
    }
}

@Composable
internal fun OrgRollupContentBody(
    isLoading: Boolean,
    rollupRows: List<OrgRollupRow>,
    selectedSegment: String,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    when {
        isLoading ->
            Box(modifier = modifier, contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        rollupRows.isEmpty() ->
            Box(modifier = modifier, contentAlignment = Alignment.Center) {
                Text(
                    text = "No seat usage data found for this window.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        else ->
            OrgRollupRowsList(
                rollupRows = rollupRows,
                selectedSegment = selectedSegment,
                isDark = isDark,
                modifier = modifier,
            )
    }
}

@Composable
private fun OrgRollupRowsList(
    rollupRows: List<OrgRollupRow>,
    selectedSegment: String,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    val totalCost = rollupRows.sumOf { it.totalCost }
    LazyColumn(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        items(rollupRows) { row ->
            val share = if (totalCost > 0.0) row.totalCost / totalCost else 0.0
            OrgRollupRowCard(row = row, share = share, selectedSegment = selectedSegment, isDark = isDark)
        }
    }
}

@Composable
private fun OrgRollupRowCard(
    row: OrgRollupRow,
    share: Double,
    selectedSegment: String,
    isDark: Boolean,
) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = row.label,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = Formatting.formatCurrency(row.totalCost),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                    color = if (isDark) AuroraColors.emberDark else AuroraColors.ember,
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "${row.totalTokens} tokens · ${row.sessionCount} sessions",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (selectedSegment != "user") {
                    Text(
                        text = "${row.deviceCount} seats",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            LinearProgressIndicator(
                progress = { share.toFloat().coerceIn(0f, 1f) },
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(4.dp),
                color = if (isDark) AuroraColors.purpleDark else AuroraColors.purple,
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
            )
        }
    }
}
