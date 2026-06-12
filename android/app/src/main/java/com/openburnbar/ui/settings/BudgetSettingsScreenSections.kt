// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.insights.BudgetCenterRulesSectionCallbacks
import com.openburnbar.ui.insights.BudgetCenterState
import com.openburnbar.ui.insights.budgetCenterActivityLogSection
import com.openburnbar.ui.insights.budgetCenterRulesSection
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BudgetSettingsScaffold(
    isDark: Boolean,
    onBack: () -> Unit,
    onAddRule: () -> Unit,
    content: @Composable () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground,
            )
            .padding(horizontal = AuroraSpacing.lg.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        BudgetSettingsHeader(onBack = onBack, onAddRule = onAddRule)
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        content()
    }
}

@Composable
internal fun BudgetSettingsHeader(onBack: () -> Unit, onAddRule: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = "Budgeting & Rules",
            style = AuroraType.displayLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onAddRule) {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = "Add Rule",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
internal fun BudgetSettingsIntroCard() {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Text(
                text = "How Budgeting Works",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Text(
                text = "Per-usage credentials get hard blocks when a rule is exceeded. Subscription credentials are exempt.",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun BudgetSettingsContent(
    state: BudgetCenterState,
    isDark: Boolean,
    onRuleDeleted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        item { BudgetSettingsIntroCard() }
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
                    onRuleDeleted()
                },
            ),
        )
        budgetCenterActivityLogSection(state.recentEvents, isDark)
    }
}
