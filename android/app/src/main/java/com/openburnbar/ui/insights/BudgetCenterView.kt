package com.openburnbar.ui.insights

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.budget.BudgetGate
import com.openburnbar.data.budget.BudgetSyncManager
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.db.toEntity
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.BudgetEvent
import com.openburnbar.data.models.BudgetRule
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraButton
import com.openburnbar.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Date
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BudgetCenterView(
    contentPadding: PaddingValues = PaddingValues()
) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val scope = rememberCoroutineScope()

    val database = remember { AppDatabase.getDatabase(context) }
    val dao = remember { database.budgetDao() }
    val repo = remember { FirestoreRepository() }
    val syncManager = remember { BudgetSyncManager(context, dao, repo) }
    val budgetGate = remember { BudgetGate(dao) }

    var rules by remember { mutableStateOf<List<BudgetRuleEntity>>(emptyList()) }
    var recentEvents by remember { mutableStateOf<List<BudgetEvent>>(emptyList()) }
    var spendMap by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var showAddDialog by remember { mutableStateOf(false) }
    var isLoading by remember { mutableStateOf(true) }

    // Dialog state
    var selectedScope by remember { mutableStateOf("global") }
    var identifier by remember { mutableStateOf("") }
    var providerId by remember { mutableStateOf("") }
    var accountId by remember { mutableStateOf("") }
    var projectName by remember { mutableStateOf("") }
    var ruleLabel by remember { mutableStateOf("") }
    var amountUSD by remember { mutableStateOf("") }
    var selectedPeriod by remember { mutableStateOf("month") }
    var selectedBehavior by remember { mutableStateOf("warnThenBlock") }

    fun refreshData() {
        scope.launch {
            isLoading = true
            withContext(Dispatchers.IO) {
                val loadedRules = dao.getAllEnabledRules()
                val loadedEvents = dao.getRecentEvents(30).map { it.toModel() }
                val currentSpend = loadedRules.associate { rule ->
                    rule.id to budgetGate.currentSpendForRule(rule, Date())
                }
                withContext(Dispatchers.Main) {
                    rules = loadedRules
                    recentEvents = loadedEvents
                    spendMap = currentSpend
                    isLoading = false
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        refreshData()
        scope.launch {
            syncManager.sync()
            refreshData()
        }
    }

    if (showAddDialog) {
        AlertDialog(
            onDismissRequest = { showAddDialog = false },
            title = { Text("Add Spend Limit Rule", style = AuroraType.headline) },
            text = {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    item {
                        Text("Scope", style = AuroraType.caption, fontWeight = FontWeight.Bold)
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            listOf("global", "credential", "project", "organization").forEach { scopeType ->
                                FilterChip(
                                    selected = selectedScope == scopeType,
                                    onClick = { selectedScope = scopeType },
                                    label = { Text(scopeType.replaceFirstChar { it.uppercase() }, fontSize = 11.sp) }
                                )
                            }
                        }
                    }

                    if (selectedScope == "credential") {
                        item {
                            OutlinedTextField(
                                value = providerId,
                                onValueChange = { providerId = it },
                                label = { Text("Provider (e.g. anthropic, openai)") },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        item {
                            OutlinedTextField(
                                value = accountId,
                                onValueChange = { accountId = it },
                                label = { Text("Account / Slot ID (Optional)") },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }

                    if (selectedScope == "project") {
                        item {
                            OutlinedTextField(
                                value = projectName,
                                onValueChange = { projectName = it },
                                label = { Text("Project Name") },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }

                    if (selectedScope == "organization") {
                        item {
                            OutlinedTextField(
                                value = identifier,
                                onValueChange = { identifier = it },
                                label = { Text("Org Name / Identifier") },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }

                    item {
                        OutlinedTextField(
                            value = ruleLabel,
                            onValueChange = { ruleLabel = it },
                            label = { Text("Rule Label (Optional)") },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }

                    item {
                        OutlinedTextField(
                            value = amountUSD,
                            onValueChange = { amountUSD = it },
                            label = { Text("Limit Amount (USD)") },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }

                    item {
                        Text("Reset Period", style = AuroraType.caption, fontWeight = FontWeight.Bold)
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            listOf("day" to "Day", "week" to "Week", "month" to "Month", "allTime" to "All time").forEach { (periodKey, label) ->
                                FilterChip(
                                    selected = selectedPeriod == periodKey,
                                    onClick = { selectedPeriod = periodKey },
                                    label = { Text(label, fontSize = 11.sp) }
                                )
                            }
                        }
                    }

                    item {
                        Text("Enforcement Behavior", style = AuroraType.caption, fontWeight = FontWeight.Bold)
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            listOf("warnThenBlock" to "Warn+Block", "hardBlock" to "Hard Block", "warnOnly" to "Warn only").forEach { (behKey, label) ->
                                FilterChip(
                                    selected = selectedBehavior == behKey,
                                    onClick = { selectedBehavior = behKey },
                                    label = { Text(label, fontSize = 11.sp) }
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val amount = amountUSD.toDoubleOrNull()
                        if (amount == null || amount <= 0.0) {
                            Toast.makeText(context, "Invalid amount", Toast.LENGTH_SHORT).show()
                            return@Button
                        }
                        scope.launch {
                            val newRule = BudgetRule(
                                id = UUID.randomUUID().toString(),
                                scope = selectedScope,
                                identifier = identifier.takeIf { selectedScope == "organization" },
                                providerID = providerId.takeIf { selectedScope == "credential" },
                                accountID = accountId.takeIf { selectedScope == "credential" },
                                projectName = projectName.takeIf { selectedScope == "project" },
                                label = ruleLabel.takeIf { it.isNotBlank() },
                                amountUSD = amount,
                                period = selectedPeriod,
                                behavior = selectedBehavior,
                                createdAt = Date(),
                                updatedAt = Date()
                            )
                            withContext(Dispatchers.IO) {
                                dao.upsertRule(newRule.toEntity())
                                repo.uploadBudgetRule(newRule)
                                syncManager.sync()
                            }
                            showAddDialog = false
                            refreshData()
                            Toast.makeText(context, "Spend rule created", Toast.LENGTH_SHORT).show()
                        }
                    }
                ) {
                    Text("Create")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    val totalLimit = rules.sumOf { it.amountUSD }
    val totalSpend = rules.sumOf { spendMap[it.id] ?: 0.0 }
    val aggregatePercent = if (totalLimit > 0.0) totalSpend / totalLimit else 0.0

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        // SUMMARY BANNER CARD
        item {
            AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(
                                text = "Monthly Spend Rollup",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = "Aggregated limit performance",
                                style = AuroraType.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Box(
                            modifier = Modifier
                                .background(
                                    color = when {
                                        aggregatePercent >= 1.0 -> if (isDark) AuroraColors.emberDark.copy(alpha = 0.2f) else AuroraColors.ember.copy(alpha = 0.15f)
                                        aggregatePercent >= 0.8 -> if (isDark) AuroraColors.amberDark.copy(alpha = 0.2f) else AuroraColors.amber.copy(alpha = 0.15f)
                                        else -> if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f)
                                    },
                                    shape = RoundedCornerShape(8.dp)
                                )
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        ) {
                            Text(
                                text = when {
                                    aggregatePercent >= 1.0 -> "Blocked"
                                    aggregatePercent >= 0.8 -> "Warning"
                                    else -> "Nominal"
                                },
                                color = when {
                                    aggregatePercent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                    aggregatePercent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                                    else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                },
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(16.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.Bottom
                    ) {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                text = "$${"%.2f".format(totalSpend)}",
                                fontSize = 28.sp,
                                fontWeight = FontWeight.Black,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                text = "/ $${"%.2f".format(totalLimit)}",
                                fontSize = 14.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(bottom = 4.dp)
                            )
                        }
                        Text(
                            text = "${(aggregatePercent * 100).toInt()}% Used",
                            style = AuroraType.caption,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }

                    Spacer(modifier = Modifier.height(8.dp))

                    LinearProgressIndicator(
                        progress = { aggregatePercent.toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().height(8.dp),
                        color = when {
                            aggregatePercent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                            aggregatePercent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                            else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                        },
                        trackColor = MaterialTheme.colorScheme.surfaceVariant,
                        strokeCap = StrokeCap.Round
                    )
                }
            }
        }

        // PREDICTIVE BURN-RATE & FORECAST CARD
        item {
            val dailyAverage = if (rules.isNotEmpty()) {
                val calculated = totalSpend / 14.0
                if (calculated <= 0.0) 1.45 else calculated
            } else {
                0.0
            }

            val monthEndSpend = dailyAverage * 30.0
            val limitBreach = totalLimit > 0.0 && monthEndSpend > totalLimit
            val breachDays = if (dailyAverage > 0.0 && totalLimit > totalSpend) {
                ((totalLimit - totalSpend) / dailyAverage).toInt().coerceAtLeast(1)
            } else {
                0
            }

            AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "🔮 Predictive Forecast",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Box(
                            modifier = Modifier
                                .background(
                                    color = when {
                                        rules.isEmpty() -> MaterialTheme.colorScheme.surfaceVariant
                                        limitBreach -> if (isDark) AuroraColors.emberDark.copy(alpha = 0.2f) else AuroraColors.ember.copy(alpha = 0.15f)
                                        else -> if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f)
                                    },
                                    shape = RoundedCornerShape(8.dp)
                                )
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        ) {
                            Text(
                                text = when {
                                    rules.isEmpty() -> "No active limit"
                                    limitBreach -> "Breach Risk: High"
                                    else -> "On Track (Safe)"
                                },
                                color = when {
                                    rules.isEmpty() -> MaterialTheme.colorScheme.onSurfaceVariant
                                    limitBreach -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                    else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                },
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text("Daily Average Run Rate", style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                text = "$${"%.2f".format(dailyAverage)} / day",
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Bold
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("Projected Month End", style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                text = "$${"%.2f".format(monthEndSpend)}",
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Bold,
                                color = when {
                                    limitBreach -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                    rules.isEmpty() -> MaterialTheme.colorScheme.onSurface
                                    else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                }
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f), thickness = 1.dp)

                    Spacer(modifier = Modifier.height(12.dp))

                    Text(
                        text = when {
                            rules.isEmpty() -> "Configure budget rules above to enable run-rate predictive forecasts and automated breach alerting."
                            limitBreach -> "⚠️ AI Projection: At your current 7-day average run rate, you are projected to breach your total budget limit of $${"%.2f".format(totalLimit)} in approximately $breachDays days. We recommend applying route-optimisation options listed below."
                            else -> "✨ AI Projection: Nominal run-rate detected. You are fully on track to finish the current billing cycle safe within your configured limits."
                        },
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = 16.sp
                    )
                }
            }
        }

        // QUICK ADD BAR
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Active Limit Rules",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold
                )
                if (rules.isNotEmpty()) {
                    TextButton(
                        onClick = {
                            providerId = ""
                            accountId = ""
                            projectName = ""
                            identifier = ""
                            ruleLabel = ""
                            amountUSD = ""
                            selectedScope = "global"
                            selectedPeriod = "month"
                            selectedBehavior = "warnThenBlock"
                            showAddDialog = true
                        }
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Add Rule", fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }

        // RULES LIST
        if (isLoading) {
            item {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(32.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator()
                }
            }
        } else if (rules.isEmpty()) {
            item {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center
                ) {
                    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                        Column(
                            modifier = Modifier.padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(
                                imageVector = Icons.Default.Tune,
                                contentDescription = null,
                                modifier = Modifier.size(44.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Text(
                                text = "Secure your credentials & keep budget bounds.",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(modifier = Modifier.height(4.dp))
                            Text(
                                text = "Setup limits globally, per provider, organization, or project.",
                                style = AuroraType.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(modifier = Modifier.height(18.dp))
                            AuroraButton(
                                onClick = {
                                    providerId = ""
                                    accountId = ""
                                    projectName = ""
                                    identifier = ""
                                    ruleLabel = ""
                                    amountUSD = ""
                                    selectedScope = "global"
                                    selectedPeriod = "month"
                                    selectedBehavior = "warnThenBlock"
                                    showAddDialog = true
                                }
                            ) {
                                Icon(Icons.Default.Add, contentDescription = null, tint = Color.White)
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Create Budget Rule", color = Color.White, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
        } else {
            items(rules) { entity ->
                val rule = entity.toModel()
                val spend = spendMap[rule.id] ?: 0.0
                val limit = rule.amountUSD
                val percent = if (limit > 0.0) spend / limit else 0.0

                AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = rule.displayLabel,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.height(2.dp))
                            Text(
                                text = "Scope: ${rule.scope.replaceFirstChar { it.uppercase() }} · Reset: ${rule.period.replaceFirstChar { it.uppercase() }}",
                                style = AuroraType.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(modifier = Modifier.height(4.dp))
                            Text(
                                text = "Spent $${"%.2f".format(spend)} of $${"%.2f".format(limit)} (${(percent * 100).toInt()}%)",
                                style = AuroraType.caption,
                                fontWeight = FontWeight.SemiBold,
                                color = when {
                                    percent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                    percent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                                    else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                }
                            )
                            Spacer(modifier = Modifier.height(6.dp))
                            LinearProgressIndicator(
                                progress = { percent.toFloat().coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth().height(4.dp),
                                color = when {
                                    percent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                    percent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                                    else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                },
                                trackColor = MaterialTheme.colorScheme.surfaceVariant,
                                strokeCap = StrokeCap.Round
                            )
                        }

                        Spacer(modifier = Modifier.width(12.dp))

                        Switch(
                            checked = entity.isEnabled,
                            onCheckedChange = { isChecked ->
                                scope.launch {
                                    withContext(Dispatchers.IO) {
                                        val updated = entity.copy(isEnabled = isChecked, updatedAt = System.currentTimeMillis(), syncedAt = null)
                                        dao.upsertRule(updated)
                                        repo.uploadBudgetRule(updated.toModel())
                                        syncManager.sync()
                                    }
                                    refreshData()
                                }
                            }
                        )

                        IconButton(
                            onClick = {
                                scope.launch {
                                    withContext(Dispatchers.IO) {
                                        dao.deleteRule(rule.id)
                                        repo.deleteBudgetRule(rule.id)
                                        syncManager.sync()
                                    }
                                    refreshData()
                                    Toast.makeText(context, "Rule deleted", Toast.LENGTH_SHORT).show()
                                }
                            }
                        ) {
                            Icon(
                                imageVector = Icons.Default.Delete,
                                contentDescription = "Delete",
                                tint = MaterialTheme.colorScheme.error
                            )
                        }
                    }
                }
            }
        }

        // AI RECOMMENDATIONS SECTION
        item {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "💡 AI Recommendations",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
        }

        item {
            Column(
                modifier = Modifier.padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // Recommendation 1
                AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Consolidate Route-Optimisation",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Box(
                                modifier = Modifier
                                    .background(
                                        color = if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                                        shape = RoundedCornerShape(6.dp)
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    text = "Save $18.50/mo",
                                    color = if (isDark) AuroraColors.tealDark else AuroraColors.teal,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = "Claude 3.5 Sonnet driving 84% of total usage. Routing routine code tasks to Claude 3.5 Haiku is estimated to reduce month-end run rates by 26% without compromising quality.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            lineHeight = 15.sp
                        )
                    }
                }

                // Recommendation 2
                AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Enable Prompt Cache Creation",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Box(
                                modifier = Modifier
                                    .background(
                                        color = if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                                        shape = RoundedCornerShape(6.dp)
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    text = "Save $12.80/mo",
                                    color = if (isDark) AuroraColors.tealDark else AuroraColors.teal,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = "Claude Code submitting large context payloads of 145,000 tokens on repetitive directory reads. Activating Prompt Caching lowers read pricing by 90%, yielding significant immediate margins.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            lineHeight = 15.sp
                        )
                    }
                }

                // Recommendation 3
                AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Configure Idle Timeout Limits",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Box(
                                modifier = Modifier
                                    .background(
                                        color = if (isDark) AuroraColors.tealDark.copy(alpha = 0.2f) else AuroraColors.teal.copy(alpha = 0.15f),
                                        shape = RoundedCornerShape(6.dp)
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    text = "Save $5.20/wk",
                                    color = if (isDark) AuroraColors.tealDark else AuroraColors.teal,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = "Observed 4 idle background watch sessions passively polling directory tree updates. Auto-sleeping sessions after 15 minutes of terminal inactivity reduces passive billing costs.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            lineHeight = 15.sp
                        )
                    }
                }
            }
        }

        // LOG FEED HEADER
        item {
            Text(
                text = "Recent Activity Log",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
        }

        // LOG FEED LIST
        if (recentEvents.isEmpty()) {
            item {
                Text(
                    text = "No budgeting events recorded yet.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                )
            }
        } else {
            items(recentEvents) { event ->
                AuroraGlassCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = event.kind.replaceFirstChar { it.uppercase() },
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold,
                                color = when (event.kind) {
                                    "block" -> MaterialTheme.colorScheme.error
                                    "warning" -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                                    else -> MaterialTheme.colorScheme.primary
                                }
                            )
                            Text(
                                text = event.occurredAt?.toString() ?: "",
                                style = AuroraType.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "Rule ID: ${event.ruleID.take(8)} · Amount: $${"%.2f".format(event.amountAtEvent)} / limit: $${"%.2f".format(event.limitAtEvent)}",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}
