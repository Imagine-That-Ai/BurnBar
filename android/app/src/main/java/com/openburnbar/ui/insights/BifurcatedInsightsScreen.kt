package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun BifurcatedInsightsScreen(
    onSelectProvider: (AgentProvider) -> Unit,
    onSelectAggregate: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isDark = isSystemInDarkTheme()
    var selectedTab by rememberSaveable { mutableStateOf("Budgeting") }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                if (isDark) AuroraColors.darkBackground
                else AuroraColors.lightBackground
            )
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        // HEADER & TITLE
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Budget & Insights",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f)
            )
        }

        // CUSTOM SLIDING SEGMENT CONTROL
        AuroraSegmentedControl(
            options = listOf("Budgeting", "Insights"),
            selectedOption = selectedTab,
            onOptionSelected = { selectedTab = it },
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
        )

        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))

        // VIEW PORT CONTAINER
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            if (selectedTab == "Budgeting") {
                BudgetCenterView(
                    contentPadding = PaddingValues(bottom = 16.dp)
                )
            } else {
                AgentInsightsRosterScreen(
                    onSelectProvider = onSelectProvider,
                    onSelectAggregate = onSelectAggregate,
                    contentPadding = PaddingValues(bottom = 16.dp)
                )
            }
        }
    }
}

@Composable
private fun AuroraSegmentedControl(
    options: List<String>,
    selectedOption: String,
    onOptionSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        options.forEach { option ->
            val isSelected = option == selectedOption
            val bgColors = if (isSelected) {
                if (isDark) listOf(AuroraColors.ember.copy(alpha = 0.25f), AuroraColors.amber.copy(alpha = 0.15f))
                else listOf(AuroraColors.ember.copy(alpha = 0.15f), AuroraColors.amber.copy(alpha = 0.08f))
            } else {
                listOf(Color.Transparent, Color.Transparent)
            }

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(18.dp))
                    .background(Brush.linearGradient(bgColors))
                    .clickable {
                        if (!isSelected) {
                            onOptionSelected(option)
                            HapticBus.tabChange(context)
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = option,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                    color = if (isSelected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
