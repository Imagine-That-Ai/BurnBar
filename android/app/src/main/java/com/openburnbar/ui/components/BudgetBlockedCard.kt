package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.ui.theme.*

@Composable
fun BudgetBlockedCard(
    rule: BudgetRuleEntity,
    used: Double,
    limit: Double,
    onRaiseLimit: (BudgetRuleEntity, Double) -> Unit,
    onAllowSession: (BudgetRuleEntity) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isDark = isSystemInDarkTheme()
    val errorColor = if (isDark) AuroraColors.emberDark else AuroraColors.ember
    val purpleColor = if (isDark) AuroraColors.purpleDark else AuroraColors.purple

    Card(
        modifier = modifier
            .fillMaxWidth()
            .border(
                width = 1.5.dp,
                color = errorColor.copy(alpha = 0.6f),
                shape = RoundedCornerShape(AuroraRadius.lg.dp)
            ),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalAlignment = Alignment.Top
        ) {
            Icon(
                imageVector = Icons.Default.Block,
                contentDescription = "Budget Limit Reached",
                tint = errorColor,
                modifier = Modifier
                    .size(36.dp)
                    .padding(top = 2.dp)
            )

            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Budget Limit Reached",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )

                Spacer(modifier = Modifier.height(2.dp))

                Text(
                    text = rule.toModel().displayLabel,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))

                Text(
                    text = "Spent $${"%.2f".format(used)} of $${"%.2f".format(limit)} per ${rule.period}",
                    style = AuroraType.caption,
                    fontWeight = FontWeight.SemiBold,
                    color = errorColor
                )

                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

                // Action buttons
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // +$25 Button (coral / error colored)
                    Button(
                        onClick = { onRaiseLimit(rule, 25.0) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = errorColor,
                            contentColor = Color.White
                        ),
                        contentPadding = PaddingValues(horizontal = AuroraSpacing.sm.dp, vertical = 4.dp),
                        modifier = Modifier.height(32.dp)
                    ) {
                        Text("+$25", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }

                    // Allow session button (purple)
                    Button(
                        onClick = { onAllowSession(rule) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = purpleColor,
                            contentColor = Color.White
                        ),
                        contentPadding = PaddingValues(horizontal = AuroraSpacing.sm.dp, vertical = 4.dp),
                        modifier = Modifier.height(32.dp)
                    ) {
                        Text("Allow session", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    // Settings button
                    IconButton(
                        onClick = onOpenSettings,
                        modifier = Modifier.size(32.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Settings,
                            contentDescription = "Budget Settings",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
    }
}
