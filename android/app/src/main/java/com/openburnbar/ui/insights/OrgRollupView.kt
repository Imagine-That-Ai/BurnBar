package com.openburnbar.ui.insights

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.models.OrgRollupRow
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Calendar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrgRollupView(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val scope = rememberCoroutineScope()

    val database = remember { AppDatabase.getDatabase(context) }
    val dao = remember { database.budgetDao() }

    var selectedSegment by remember { mutableStateOf("user") } // user, project, credential, provider
    var selectedPeriod by remember { mutableStateOf("month") } // day, week, month, allTime
    var rollupRows by remember { mutableStateOf<List<OrgRollupRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }

    // Gate setting
    val sharedPrefs = remember(context) { context.getSharedPreferences("burnbar_enterprise", Context.MODE_PRIVATE) }
    var enterpriseOrgViewEnabled by remember {
        mutableStateOf(sharedPrefs.getBoolean("enterpriseOrgViewEnabled", true)) // default on for SOTA parity
    }

    fun loadRollup() {
        scope.launch {
            isLoading = true
            withContext(Dispatchers.IO) {
                val calendar = Calendar.getInstance()
                val nowMs = System.currentTimeMillis()

                val windowStart = when (selectedPeriod) {
                    "day" -> {
                        calendar.set(Calendar.HOUR_OF_DAY, 0)
                        calendar.set(Calendar.MINUTE, 0)
                        calendar.set(Calendar.SECOND, 0)
                        calendar.set(Calendar.MILLISECOND, 0)
                        calendar.timeInMillis
                    }
                    "week" -> {
                        calendar.set(Calendar.HOUR_OF_DAY, 0)
                        calendar.set(Calendar.MINUTE, 0)
                        calendar.set(Calendar.SECOND, 0)
                        calendar.set(Calendar.MILLISECOND, 0)
                        calendar.set(Calendar.DAY_OF_WEEK, calendar.firstDayOfWeek)
                        calendar.timeInMillis
                    }
                    "month" -> {
                        calendar.set(Calendar.HOUR_OF_DAY, 0)
                        calendar.set(Calendar.MINUTE, 0)
                        calendar.set(Calendar.SECOND, 0)
                        calendar.set(Calendar.MILLISECOND, 0)
                        calendar.set(Calendar.DAY_OF_MONTH, 1)
                        calendar.timeInMillis
                    }
                    else -> 0L
                }

                val loaded = when (selectedSegment) {
                    "user" -> dao.orgRollupByUser(windowStart, 50)
                    "project" -> dao.orgRollupByProject(windowStart, 50)
                    "credential" -> dao.orgRollupByCredential(windowStart, 50)
                    "provider" -> dao.orgRollupByProvider(windowStart, 50)
                    else -> emptyList()
                }

                withContext(Dispatchers.Main) {
                    rollupRows = loaded
                    isLoading = false
                }
            }
        }
    }

    LaunchedEffect(selectedSegment, selectedPeriod, enterpriseOrgViewEnabled) {
        if (enterpriseOrgViewEnabled) {
            loadRollup()
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                if (isDark) AuroraColors.darkBackground
                else AuroraColors.lightBackground
            )
            .padding(horizontal = AuroraSpacing.lg.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        // Hero Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = Icons.Default.Business,
                contentDescription = "Enterprise Rollup",
                tint = if (isDark) AuroraColors.purpleDark else AuroraColors.purple,
                modifier = Modifier.size(28.dp)
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Column {
                Text(
                    text = "ENTERPRISE",
                    style = AuroraType.caption,
                    fontWeight = FontWeight.Bold,
                    color = if (isDark) AuroraColors.purpleDark else AuroraColors.purple
                )
                Text(
                    text = "Cross-Seat Spend Rollup",
                    style = AuroraType.displayLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        if (!enterpriseOrgViewEnabled) {
            // Locked Gate Screen
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center
            ) {
                AuroraGlassCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(AuroraSpacing.lg.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(AuroraSpacing.lg.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.Lock,
                            contentDescription = "Enterprise Gated",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(48.dp)
                        )
                        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                        Text(
                            text = "Enterprise View Disabled",
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                        Text(
                            text = "Enable enterpriseOrgViewEnabled settings to aggregate cross-device token spends, cost metrics, and device seat counts.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                        Button(
                            onClick = {
                                enterpriseOrgViewEnabled = true
                                sharedPrefs.edit().putBoolean("enterpriseOrgViewEnabled", true).apply()
                            }
                        ) {
                            Text("Enable Dashboard")
                        }
                    }
                }
            }
            return
        }

        // Filters Section
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Segment picker
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("user" to "User", "project" to "Proj", "credential" to "Cred", "provider" to "Prov").forEach { (segmentKey, label) ->
                    FilterChip(
                        selected = selectedSegment == segmentKey,
                        onClick = { selectedSegment = segmentKey },
                        label = { Text(label, fontSize = 10.sp) },
                        modifier = Modifier.height(28.dp)
                    )
                }
            }

            // Period picker
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("day" to "D", "week" to "W", "month" to "M", "allTime" to "All").forEach { (periodKey, label) ->
                    FilterChip(
                        selected = selectedPeriod == periodKey,
                        onClick = { selectedPeriod = periodKey },
                        label = { Text(label, fontSize = 10.sp) },
                        modifier = Modifier.height(28.dp)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        // Rollup Rows
        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else if (rollupRows.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "No seat usage data found for this window.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            val totalCost = rollupRows.sumOf { it.totalCost }

            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                items(rollupRows) { row ->
                    val share = if (totalCost > 0.0) row.totalCost / totalCost else 0.0

                    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(AuroraSpacing.md.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = row.label,
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                                Text(
                                    text = "$${"%.2f".format(row.totalCost)}",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Bold,
                                    color = if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                )
                            }

                            Spacer(modifier = Modifier.height(4.dp))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = "${row.totalTokens} tokens · ${row.sessionCount} sessions",
                                    style = AuroraType.caption,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                if (selectedSegment != "user") {
                                    Text(
                                        text = "${row.deviceCount} seats",
                                        style = AuroraType.caption,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }

                            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))

                            // Share Percentage Bar
                            LinearProgressIndicator(
                                progress = { share.toFloat().coerceIn(0f, 1f) },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(4.dp),
                                color = if (isDark) AuroraColors.purpleDark else AuroraColors.purple,
                                trackColor = MaterialTheme.colorScheme.surfaceVariant
                            )
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
    }
}
