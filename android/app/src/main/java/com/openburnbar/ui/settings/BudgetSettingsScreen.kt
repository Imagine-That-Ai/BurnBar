package com.openburnbar.ui.settings

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.budget.BudgetGate
import com.openburnbar.data.budget.BudgetSyncManager
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.db.toEntity
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.*
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
fun BudgetSettingsScreen(
    onBack: () -> Unit
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
                // Fetch fresh rules and events from Room
                val loadedRules = dao.getAllEnabledRules()
                val loadedEvents = dao.getRecentEvents(50).map { it.toModel() }

                // Fetch spend per rule
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
            // Background sync on screen load
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

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(
                if (isDark) AuroraColors.darkBackground
                else AuroraColors.lightBackground
            )
            .padding(horizontal = AuroraSpacing.lg.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = MaterialTheme.colorScheme.onSurface
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text(
                text = "Budgeting & Rules",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f)
            )
            IconButton(
                onClick = {
                    // Reset dialogue fields and show
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
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = "Add Rule",
                    tint = MaterialTheme.colorScheme.onSurface
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            modifier = Modifier.fillMaxWidth().weight(1f)
        ) {
            // Intro Information Card
            item {
                AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
                        Text(
                            text = "How Budgeting Works",
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                        Text(
                            text = "Per-usage credentials get hard blocks when a rule is exceeded. Subscription credentials are exempt.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Rules List
            item {
                Text("Active Limit Rules", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
            }

            if (isLoading) {
                item {
                    Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
            } else if (rules.isEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text(
                            text = "No budget rules configured yet. Tap '+' to create one.",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 16.dp)
                        )
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
                            },
                            modifier = Modifier.wrapContentSize()
                        ) {
                            Icon(
                                imageVector = Icons.Default.Add,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                                tint = Color.White
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                "Create Limit Rule",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }
                    }
                }
            } else {
                items(rules) { entity ->
                    val rule = entity.toModel()
                    val spend = spendMap[rule.id] ?: 0.0
                    val limit = rule.amountUSD
                    val percent = if (limit > 0.0) spend / limit else 0.0

                    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier.padding(AuroraSpacing.md.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = rule.displayLabel,
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Bold
                                )
                                Spacer(modifier = Modifier.height(2.dp))
                                Text(
                                    text = "Scope: ${rule.scope.replaceFirstChar { it.uppercase() }} · Period: ${rule.period.replaceFirstChar { it.uppercase() }}",
                                    style = AuroraType.caption,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
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
                                Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                                LinearProgressIndicator(
                                    progress = { percent.toFloat().coerceIn(0f, 1f) },
                                    modifier = Modifier.fillMaxWidth().height(4.dp),
                                    color = when {
                                        percent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                                        percent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                                        else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
                                    },
                                    trackColor = MaterialTheme.colorScheme.surfaceVariant
                                )
                            }

                            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))

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

            // Events Log
            item {
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                Text("Recent Activity Log", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
            }

            if (recentEvents.isEmpty()) {
                item {
                    Text(
                        "No budgeting events recorded yet.",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp)
                    )
                }
            } else {
                items(recentEvents) { event ->
                    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween
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
                            Spacer(modifier = Modifier.height(2.dp))
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
}
