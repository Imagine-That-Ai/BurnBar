// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.BudgetRule
import com.openburnbar.ui.theme.AuroraType
import java.util.Date

@Composable
internal fun BudgetAddRuleDialog(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
    onDismiss: () -> Unit,
    onCreate: (BudgetRule) -> Unit,
) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Spend Limit Rule", style = AuroraType.headline) },
        text = { BudgetAddRuleDialogForm(form = form, onFormChange = onFormChange) },
        confirmButton = {
            Button(
                onClick = {
                    val amount = form.amountUSD.toDoubleOrNull()
                    if (amount == null || amount <= 0.0) {
                        Toast.makeText(context, "Invalid amount", Toast.LENGTH_SHORT).show()
                        return@Button
                    }
                    onCreate(
                        BudgetRule(
                            id = java.util.UUID.randomUUID().toString(),
                            scope = form.selectedScope,
                            identifier = form.identifier.takeIf { form.selectedScope == "organization" },
                            providerID = form.providerId.takeIf { form.selectedScope == "credential" },
                            accountID = form.accountId.takeIf { form.selectedScope == "credential" },
                            projectName = form.projectName.takeIf { form.selectedScope == "project" },
                            label = form.ruleLabel.takeIf { it.isNotBlank() },
                            amountUSD = amount,
                            period = form.selectedPeriod,
                            behavior = form.selectedBehavior,
                            createdAt = Date(),
                            updatedAt = Date(),
                        ),
                    )
                },
            ) {
                Text("Create")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

@Composable
private fun BudgetAddRuleDialogForm(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        budgetAddRuleScopeSection(form, onFormChange)
        budgetAddRuleScopeFieldsSection(form, onFormChange)
        budgetAddRuleAmountSection(form, onFormChange)
        budgetAddRulePeriodSection(form, onFormChange)
        budgetAddRuleBehaviorSection(form, onFormChange)
    }
}

private fun LazyListScope.budgetAddRuleScopeSection(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    item {
        Text("Scope", style = AuroraType.caption, fontWeight = FontWeight.Bold)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.fillMaxWidth()) {
            listOf("global", "credential", "project", "organization").forEach { scopeType ->
                FilterChip(
                    selected = form.selectedScope == scopeType,
                    onClick = { onFormChange(form.copy(selectedScope = scopeType)) },
                    label = { Text(scopeType.replaceFirstChar { it.uppercase() }, fontSize = 11.sp) },
                )
            }
        }
    }
}

private fun LazyListScope.budgetAddRuleScopeFieldsSection(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    if (form.selectedScope == "credential") {
        item {
            OutlinedTextField(
                value = form.providerId,
                onValueChange = { onFormChange(form.copy(providerId = it)) },
                label = { Text("Provider (e.g. anthropic, openai)") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        item {
            OutlinedTextField(
                value = form.accountId,
                onValueChange = { onFormChange(form.copy(accountId = it)) },
                label = { Text("Account / Slot ID (Optional)") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    if (form.selectedScope == "project") {
        item {
            OutlinedTextField(
                value = form.projectName,
                onValueChange = { onFormChange(form.copy(projectName = it)) },
                label = { Text("Project Name") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    if (form.selectedScope == "organization") {
        item {
            OutlinedTextField(
                value = form.identifier,
                onValueChange = { onFormChange(form.copy(identifier = it)) },
                label = { Text("Org Name / Identifier") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun LazyListScope.budgetAddRuleAmountSection(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    item {
        OutlinedTextField(
            value = form.ruleLabel,
            onValueChange = { onFormChange(form.copy(ruleLabel = it)) },
            label = { Text("Rule Label (Optional)") },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    item {
        OutlinedTextField(
            value = form.amountUSD,
            onValueChange = { onFormChange(form.copy(amountUSD = it)) },
            label = { Text("Limit Amount (USD)") },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun LazyListScope.budgetAddRulePeriodSection(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    item {
        Text("Reset Period", style = AuroraType.caption, fontWeight = FontWeight.Bold)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf("day" to "Day", "week" to "Week", "month" to "Month", "allTime" to "All time").forEach { (periodKey, label) ->
                FilterChip(
                    selected = form.selectedPeriod == periodKey,
                    onClick = { onFormChange(form.copy(selectedPeriod = periodKey)) },
                    label = { Text(label, fontSize = 11.sp) },
                )
            }
        }
    }
}

private fun LazyListScope.budgetAddRuleBehaviorSection(
    form: BudgetAddRuleFormState,
    onFormChange: (BudgetAddRuleFormState) -> Unit,
) {
    item {
        Text("Enforcement Behavior", style = AuroraType.caption, fontWeight = FontWeight.Bold)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf("warnThenBlock" to "Warn+Block", "hardBlock" to "Hard Block", "warnOnly" to "Warn only").forEach { (behKey, label) ->
                FilterChip(
                    selected = form.selectedBehavior == behKey,
                    onClick = { onFormChange(form.copy(selectedBehavior = behKey)) },
                    label = { Text(label, fontSize = 11.sp) },
                )
            }
        }
    }
}
