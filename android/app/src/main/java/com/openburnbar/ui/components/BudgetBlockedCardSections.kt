@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun BudgetBlockedCardActions(
    rule: BudgetRuleEntity,
    errorColor: Color,
    purpleColor: Color,
    onRaiseLimit: (BudgetRuleEntity, Double) -> Unit,
    onAllowSession: (BudgetRuleEntity) -> Unit,
    onOpenSettings: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Button(
            onClick = { onRaiseLimit(rule, 25.0) },
            colors =
            ButtonDefaults.buttonColors(
                containerColor = errorColor,
                contentColor = Color.White,
            ),
            contentPadding = PaddingValues(horizontal = AuroraSpacing.sm.dp, vertical = 4.dp),
            modifier = Modifier.height(32.dp),
        ) {
            Text("+$25", fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Button(
            onClick = { onAllowSession(rule) },
            colors =
            ButtonDefaults.buttonColors(
                containerColor = purpleColor,
                contentColor = Color.White,
            ),
            contentPadding = PaddingValues(horizontal = AuroraSpacing.sm.dp, vertical = 4.dp),
            modifier = Modifier.height(32.dp),
        ) {
            Text("Allow session", fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(modifier = Modifier.weight(1f))
        IconButton(onClick = onOpenSettings, modifier = Modifier.size(32.dp)) {
            Icon(
                imageVector = Icons.Default.Settings,
                contentDescription = "Budget Settings",
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
internal fun BudgetBlockedCardSummary(rule: BudgetRuleEntity, used: Double, limit: Double, errorColor: Color) {
    Text(
        text = "Budget Limit Reached",
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurface,
    )
    Spacer(modifier = Modifier.height(2.dp))
    Text(
        text = rule.toModel().displayLabel,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
    Text(
        text = "Spent $${"%.2f".format(used)} of $${"%.2f".format(limit)} per ${rule.period}",
        style = AuroraType.caption,
        fontWeight = FontWeight.SemiBold,
        color = errorColor,
    )
}
