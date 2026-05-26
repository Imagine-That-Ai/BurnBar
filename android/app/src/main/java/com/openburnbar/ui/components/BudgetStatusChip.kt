package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Wallet
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.ui.theme.*

@Composable
fun BudgetStatusChip(
    rules: List<BudgetRuleEntity>,
    spendByRule: Map<String, Double>,
    modifier: Modifier = Modifier
) {
    val isDark = isSystemInDarkTheme()

    // Find the worst rule that is >= 50% utilized
    val activeRules = rules.filter { it.isEnabled && it.amountUSD > 0.0 }
    val worstUtilization = activeRules.mapNotNull { rule ->
        val spend = spendByRule[rule.id] ?: 0.0
        val limit = rule.amountUSD
        val percent = spend / limit
        if (percent >= 0.5) {
            Triple(rule, spend, percent)
        } else {
            null
        }
    }.maxByOrNull { it.third } ?: return // Omit if no rule exceeds 50% usage

    val (rule, spend, percent) = worstUtilization
    val limit = rule.amountUSD

    val chipColor = when {
        percent >= 1.0 -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
        percent >= 0.8 -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
        else -> if (isDark) AuroraColors.tealDark else AuroraColors.teal
    }

    Surface(
        modifier = modifier
            .height(24.dp),
        shape = RoundedCornerShape(AuroraRadius.full.dp),
        color = chipColor.copy(alpha = 0.15f),
        border = androidx.compose.foundation.BorderStroke(
            width = 1.dp,
            color = chipColor.copy(alpha = 0.6f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxHeight()
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .background(chipColor, RoundedCornerShape(3.dp))
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "$${spend.toInt()}/$${limit.toInt()}",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = if (isDark) Color.White else Color.Black
            )
        }
    }
}
