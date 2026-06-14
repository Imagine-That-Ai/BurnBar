// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun BudgetBlockedCard(
    rule: BudgetRuleEntity,
    used: Double,
    limit: Double,
    onRaiseLimit: (BudgetRuleEntity, Double) -> Unit,
    onAllowSession: (BudgetRuleEntity) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isDark = isSystemInDarkTheme()
    val errorColor = if (isDark) AuroraColors.emberDark else AuroraColors.ember
    val purpleColor = if (isDark) AuroraColors.purpleDark else AuroraColors.purple

    Card(
        modifier =
        modifier
            .fillMaxWidth()
            .border(
                width = 1.5.dp,
                color = errorColor.copy(alpha = 0.6f),
                shape = RoundedCornerShape(AuroraRadius.LG.dp),
            ),
        colors =
        CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        ),
    ) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.MD.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                imageVector = Icons.Default.Block,
                contentDescription = "Budget Limit Reached",
                tint = errorColor,
                modifier = Modifier.size(36.dp).padding(top = 2.dp),
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
            Column(modifier = Modifier.weight(1f)) {
                BudgetBlockedCardSummary(rule = rule, used = used, limit = limit, errorColor = errorColor)
                Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
                BudgetBlockedCardActions(
                    rule = rule,
                    errorColor = errorColor,
                    purpleColor = purpleColor,
                    onRaiseLimit = onRaiseLimit,
                    onAllowSession = onAllowSession,
                    onOpenSettings = onOpenSettings,
                )
            }
        }
    }
}
