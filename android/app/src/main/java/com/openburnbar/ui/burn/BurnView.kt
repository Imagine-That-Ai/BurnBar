package com.openburnbar.ui.burn

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.roundToInt

@Composable
fun BurnView(
    quotaStore: QuotaStore = viewModel(),
    demoDataStore: DemoDataStore = viewModel(),
    dashboardStore: DashboardStore = viewModel(),
    activityStore: ActivityStore = viewModel(),
) {
    BurnViewContent(
        quotaStore = quotaStore,
        demoDataStore = demoDataStore,
        dashboardStore = dashboardStore,
        activityStore = activityStore,
    )
}

// ── Provider Ring Strip ──

@Composable
fun ProviderRingStrip(snapshots: List<ProviderQuotaSnapshot>, onProviderClick: (ProviderQuotaSnapshot) -> Unit, modifier: Modifier = Modifier) {
    LazyRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        items(snapshots) { snapshot ->
            val provider = AgentProvider.fromKey(snapshot.provider)
            ProviderChip(
                snapshot = snapshot,
                provider = provider,
                onClick = { onProviderClick(snapshot) },
            )
        }
    }
}

@Composable
fun ProviderChip(snapshot: ProviderQuotaSnapshot, provider: AgentProvider?, onClick: () -> Unit) {
    Row(
        modifier =
        Modifier
            .clickable { onClick() }
            .auroraGlass(
                cornerRadius = AuroraRadius.MD.dp,
                tintAlpha = 0.42f,
                shadow = AuroraShadows.small,
            )
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderAvatar(providerKey = snapshot.provider, size = 24)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Column {
            Text(
                provider?.displayName ?: snapshot.provider,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                "${snapshot.percentageRemaining.roundToInt()}%",
                fontSize = 11.sp,
                color =
                if (snapshot.percentageRemaining <= 25) {
                    AuroraColors.burnOrange
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
    }
}

// ── Urgent Banner ──

@Composable
fun UrgentBanner(count: Int, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(AuroraRadius.MD.dp),
        color = AuroraColors.burnOrange.copy(alpha = 0.15f),
    ) {
        Row(
            modifier = Modifier.padding(AuroraSpacing.MD.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = AuroraColors.burnOrange, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
            Text(
                "$count provider(s) below 25% quota",
                color = AuroraColors.burnOrange,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
internal fun DefaultWindowSelector(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val prefs = remember(context) { QuotaPreferences.get(context) }
    val current by prefs.defaultWindow.collectAsState()
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Text(
            "Default window",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        listOf(QuotaWindowKind.FIVE_HOUR, QuotaWindowKind.SEVEN_DAY).forEach { option ->
            val selected = current == option
            Surface(
                onClick = { prefs.setDefaultWindow(option) },
                shape = RoundedCornerShape(AuroraRadius.FULL.dp),
                color = if (selected) AuroraColors.ember.copy(alpha = 0.18f) else Color.Transparent,
                border =
                BorderStroke(
                    1.dp,
                    if (selected) AuroraColors.ember else AuroraColors.lightBorder.copy(alpha = 0.5f),
                ),
            ) {
                Text(
                    text = option.shortLabel,
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color =
                    if (selected) {
                        AuroraColors.ember
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.padding(horizontal = AuroraSpacing.MD.dp, vertical = 6.dp),
                )
            }
        }
    }
}
