package com.openburnbar.ui.insights

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.budget.BudgetGate
import com.openburnbar.data.budget.BudgetSyncManager
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.BudgetDatabaseAccess
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.db.toEntity
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.BudgetEvent
import com.openburnbar.data.models.BudgetRule
import com.openburnbar.ui.theme.AuroraSpacing
import java.util.Date
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val RECENT_BUDGET_EVENTS_LIMIT = 30

internal class BudgetCenterDependencies(
    val scope: CoroutineScope,
    val dao: BudgetDatabaseAccess,
    val repo: FirestoreRepository,
    val syncManager: BudgetSyncManager,
    val budgetGate: BudgetGate,
)

internal data class BudgetAddRuleFormState(
    val selectedScope: String = "global",
    val identifier: String = "",
    val providerId: String = "",
    val accountId: String = "",
    val projectName: String = "",
    val ruleLabel: String = "",
    val amountUSD: String = "",
    val selectedPeriod: String = "month",
    val selectedBehavior: String = "warnThenBlock",
) {
    fun cleared(): BudgetAddRuleFormState = BudgetAddRuleFormState()
}

internal data class BudgetCenterSnapshot(
    val rules: List<BudgetRuleEntity>,
    val recentEvents: List<BudgetEvent>,
    val spendMap: Map<String, Double>,
    val showAddDialog: Boolean,
    val isLoading: Boolean,
    val addRuleForm: BudgetAddRuleFormState,
)

internal data class BudgetCenterActions(
    val openAddRuleDialog: () -> Unit,
    val onAddRuleFormChange: (BudgetAddRuleFormState) -> Unit,
    val dismissAddDialog: () -> Unit,
    val onRuleCreated: (BudgetRule) -> Unit,
    val onToggleRule: (BudgetRuleEntity, Boolean) -> Unit,
    val onDeleteRule: (BudgetRule) -> Unit,
)

internal data class BudgetCenterState(
    val snapshot: BudgetCenterSnapshot,
    val actions: BudgetCenterActions,
) {
    val rules get() = snapshot.rules
    val recentEvents get() = snapshot.recentEvents
    val spendMap get() = snapshot.spendMap
    val showAddDialog get() = snapshot.showAddDialog
    val isLoading get() = snapshot.isLoading
    val addRuleForm get() = snapshot.addRuleForm
    val openAddRuleDialog get() = actions.openAddRuleDialog
    val onAddRuleFormChange get() = actions.onAddRuleFormChange
    val dismissAddDialog get() = actions.dismissAddDialog
    val onRuleCreated get() = actions.onRuleCreated
    val onToggleRule get() = actions.onToggleRule
    val onDeleteRule get() = actions.onDeleteRule
}

@Composable
internal fun rememberBudgetCenterState(context: android.content.Context): BudgetCenterState {
    val deps = rememberBudgetCenterDependencies(context)
    return rememberBudgetCenterLocalState(deps).toBudgetCenterState()
}

@Composable
private fun rememberBudgetCenterDependencies(context: android.content.Context): BudgetCenterDependencies {
    val scope = rememberCoroutineScope()
    val database = remember { AppDatabase.getDatabase(context) }
    val dao = remember { database.budgetDatabaseAccess() }
    val repo = remember { FirestoreRepository() }
    val syncManager = remember { BudgetSyncManager(context, dao, repo) }
    val budgetGate = remember { BudgetGate(dao) }
    return BudgetCenterDependencies(scope, dao, repo, syncManager, budgetGate)
}

private data class BudgetCenterLocalState(
    val snapshot: BudgetCenterSnapshot,
    val actions: BudgetCenterActions,
)

@Composable
private fun rememberBudgetCenterLocalState(deps: BudgetCenterDependencies): BudgetCenterLocalState {
    var rules by remember { mutableStateOf<List<BudgetRuleEntity>>(emptyList()) }
    var recentEvents by remember { mutableStateOf<List<BudgetEvent>>(emptyList()) }
    var spendMap by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var showAddDialog by remember { mutableStateOf(false) }
    var isLoading by remember { mutableStateOf(true) }
    var addRuleForm by remember { mutableStateOf(BudgetAddRuleFormState()) }

    fun refreshData() {
        deps.scope.launch {
            isLoading = true
            withContext(Dispatchers.IO) {
                val loadedRules = deps.dao.getAllEnabledRules()
                val loadedEvents = deps.dao.getRecentEvents(RECENT_BUDGET_EVENTS_LIMIT).map { it.toModel() }
                val currentSpend =
                    loadedRules.associate { rule ->
                        rule.id to deps.budgetGate.currentSpendForRule(rule, Date())
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
        deps.scope.launch {
            deps.syncManager.sync()
            refreshData()
        }
    }

    return BudgetCenterLocalState(
        snapshot =
        BudgetCenterSnapshot(
            rules = rules,
            recentEvents = recentEvents,
            spendMap = spendMap,
            showAddDialog = showAddDialog,
            isLoading = isLoading,
            addRuleForm = addRuleForm,
        ),
        actions =
        BudgetCenterActions(
            openAddRuleDialog = {
                addRuleForm = addRuleForm.cleared()
                showAddDialog = true
            },
            onAddRuleFormChange = { addRuleForm = it },
            dismissAddDialog = { showAddDialog = false },
            onRuleCreated = budgetCenterOnRuleCreated(deps, { refreshData() }, { showAddDialog = false }),
            onToggleRule = budgetCenterOnToggleRule(deps, { refreshData() }),
            onDeleteRule = budgetCenterOnDeleteRule(deps, { refreshData() }),
        ),
    )
}

private fun BudgetCenterLocalState.toBudgetCenterState(): BudgetCenterState =
    BudgetCenterState(snapshot = snapshot, actions = actions)

private fun budgetCenterOnRuleCreated(
    deps: BudgetCenterDependencies,
    refreshData: () -> Unit,
    dismissDialog: () -> Unit,
): (BudgetRule) -> Unit =
    { newRule ->
        deps.scope.launch {
            withContext(Dispatchers.IO) {
                deps.dao.upsertRule(newRule.toEntity())
                deps.repo.budget.uploadBudgetRule(newRule)
                deps.syncManager.sync()
            }
            dismissDialog()
            refreshData()
        }
    }

private fun budgetCenterOnToggleRule(
    deps: BudgetCenterDependencies,
    refreshData: () -> Unit,
): (BudgetRuleEntity, Boolean) -> Unit =
    { entity, isChecked ->
        deps.scope.launch {
            withContext(Dispatchers.IO) {
                val updated = entity.copy(isEnabled = isChecked, updatedAt = System.currentTimeMillis(), syncedAt = null)
                deps.dao.upsertRule(updated)
                deps.repo.budget.uploadBudgetRule(updated.toModel())
                deps.syncManager.sync()
            }
            refreshData()
        }
    }

private fun budgetCenterOnDeleteRule(
    deps: BudgetCenterDependencies,
    refreshData: () -> Unit,
): (BudgetRule) -> Unit =
    { rule ->
        deps.scope.launch {
            withContext(Dispatchers.IO) {
                deps.dao.deleteRule(rule.id)
                deps.repo.budget.deleteBudgetRule(rule.id)
                deps.syncManager.sync()
            }
            refreshData()
        }
    }

@Composable
internal fun BudgetCenterContent(
    state: BudgetCenterState,
    contentPadding: PaddingValues,
    isDark: Boolean,
    onRuleDeletedToast: () -> Unit,
) {
    val totalLimit = state.rules.sumOf { it.amountUSD }
    val totalSpend = state.rules.sumOf { state.spendMap[it.id] ?: 0.0 }
    val aggregatePercent = if (totalLimit > 0.0) totalSpend / totalLimit else 0.0

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        item { BudgetCenterSummaryBanner(totalSpend, totalLimit, aggregatePercent, isDark) }
        item { BudgetCenterForecastCard(state.rules, totalSpend, totalLimit, isDark) }
        budgetCenterRulesSection(
            isLoading = state.isLoading,
            rules = state.rules,
            spendMap = state.spendMap,
            isDark = isDark,
            callbacks =
            BudgetCenterRulesSectionCallbacks(
                onAddRule = state.openAddRuleDialog,
                onToggleRule = state.onToggleRule,
                onDeleteRule = { rule ->
                    state.onDeleteRule(rule)
                    onRuleDeletedToast()
                },
            ),
        )
        item { BudgetCenterAiRecommendationsHeader() }
        item { BudgetCenterAiRecommendationsList(isDark) }
        budgetCenterActivityLogSection(state.recentEvents, isDark)
    }
}
