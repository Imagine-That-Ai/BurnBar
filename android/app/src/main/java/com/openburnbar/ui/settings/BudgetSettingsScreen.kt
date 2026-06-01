package com.openburnbar.ui.settings

import android.widget.Toast
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.ui.insights.BudgetAddRuleDialog
import com.openburnbar.ui.insights.rememberBudgetCenterState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BudgetSettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val state = rememberBudgetCenterState(context)

    if (state.showAddDialog) {
        BudgetAddRuleDialog(
            form = state.addRuleForm,
            onFormChange = state.onAddRuleFormChange,
            onDismiss = state.dismissAddDialog,
            onCreate = { rule ->
                state.onRuleCreated(rule)
                Toast.makeText(context, "Spend rule created", Toast.LENGTH_SHORT).show()
            },
        )
    }

    BudgetSettingsScaffold(
        isDark = isDark,
        onBack = onBack,
        onAddRule = state.openAddRuleDialog,
    ) {
        BudgetSettingsContent(
            state = state,
            isDark = isDark,
            modifier = Modifier.fillMaxWidth(),
            onRuleDeleted = {
                Toast.makeText(context, "Rule deleted", Toast.LENGTH_SHORT).show()
            },
        )
    }
}
