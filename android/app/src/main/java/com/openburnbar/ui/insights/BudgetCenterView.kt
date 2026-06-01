@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import android.widget.Toast
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BudgetCenterView(contentPadding: PaddingValues = PaddingValues()) {
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

    BudgetCenterContent(
        state = state,
        contentPadding = contentPadding,
        isDark = isDark,
        onRuleDeletedToast = {
            Toast.makeText(context, "Rule deleted", Toast.LENGTH_SHORT).show()
        },
    )
}
