@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Divider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.ui.burn.buildQuotaRingItems
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.unit.dp

@Composable
fun QuotaPulseCard(snapshots: List<ProviderQuotaSnapshot>, onSelect: (String) -> Unit, onOpenBurn: () -> Unit) {
    val ui = rememberQuotaPulseCardUi(snapshots)
    val haptic = LocalHapticFeedback.current

    AuroraGlassCard(
        modifier =
        Modifier
            .padding(horizontal = AuroraSpacing.lg.dp)
            .pointerInput(Unit) {
                detectTapGestures(
                    onLongPress = {
                        if (!ui.isJiggling) {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            ui.onJigglingChange(true)
                        }
                    },
                )
            },
        cornerRadius = AuroraRadius.xl,
    ) {
        Column {
            QuotaPulseCardHeader(
                isJiggling = ui.isJiggling,
                statusColor = ui.fleetMeta.statusColor,
                percentageDisplayMode = ui.percentageDisplayMode,
                prefs = ui.prefs,
                onOpenBurn = onOpenBurn,
                onDoneJiggling = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    ui.onJigglingChange(false)
                },
            )

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            when {
                ui.items.isEmpty() && !ui.isJiggling ->
                    EmptyStateView(
                        title = "No quota signal yet",
                        message = "Connect a provider on your Mac to start tracking quota.",
                    )
                ui.isJiggling -> QuotaPulseJigglingList(
                    QuotaPulseJiggleListState(
                        providerOrder = ui.providerOrder,
                        visibleProviders = ui.visibleProviders,
                        snapshots = snapshots,
                        prefs = ui.prefs,
                        hiddenBuckets = ui.hiddenBuckets,
                        bucketOrders = ui.bucketOrders,
                        percentageDisplayMode = ui.percentageDisplayMode,
                    ),
                )
                else -> QuotaPulseDefaultBody(
                    items = ui.items,
                    fleetMeta = ui.fleetMeta,
                    onSelect = onSelect,
                    onOpenBurn = onOpenBurn,
                )
            }
        }
    }
}

private data class QuotaPulseCardUiState(
    val prefs: QuotaPreferences,
    val providerOrder: List<AgentProvider>,
    val visibleProviders: Set<AgentProvider>,
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val percentageDisplayMode: String,
    val isJiggling: Boolean,
    val items: List<com.openburnbar.ui.burn.QuotaRingItem>,
    val fleetMeta: QuotaFleetMeta,
    val onJigglingChange: (Boolean) -> Unit,
)

@Composable
private fun rememberQuotaPulseCardUi(snapshots: List<ProviderQuotaSnapshot>): QuotaPulseCardUiState {
    val context = LocalContext.current
    val prefs = remember(context) { QuotaPreferences.get(context) }
    val providerOrder by prefs.providerOrder.collectAsState()
    val visibleProviders by prefs.visibleProviders.collectAsState()
    val hiddenBuckets by prefs.hiddenBuckets.collectAsState()
    val bucketOrders by prefs.bucketOrders.collectAsState()
    val percentageDisplayMode by prefs.percentageDisplayMode.collectAsState()
    var isJiggling by remember { mutableStateOf(false) }
    val items =
        remember(snapshots, visibleProviders) {
            buildQuotaRingItems(snapshots).filter {
                val provider = AgentProvider.fromKey(it.providerKey)
                provider != null && visibleProviders.contains(provider)
            }
        }
    val fleetMeta = remember(snapshots, items) { computeQuotaFleetMeta(snapshots = snapshots, items = items) }
    return QuotaPulseCardUiState(
        prefs = prefs,
        providerOrder = providerOrder,
        visibleProviders = visibleProviders,
        hiddenBuckets = hiddenBuckets,
        bucketOrders = bucketOrders,
        percentageDisplayMode = percentageDisplayMode,
        isJiggling = isJiggling,
        items = items,
        fleetMeta = fleetMeta,
        onJigglingChange = { isJiggling = it },
    )
}

private data class QuotaFleetMeta(
    val fleetHealth: Double,
    val statusColor: androidx.compose.ui.graphics.Color,
    val fleetSubtitle: String,
)

private fun computeQuotaFleetMeta(
    snapshots: List<ProviderQuotaSnapshot>,
    items: List<com.openburnbar.ui.burn.QuotaRingItem>,
): QuotaFleetMeta {
    val hasUrgent =
        snapshots.flatMap { it.buckets }.any { bucket ->
            bucket.displayRemainingFraction ?: 1.0 < 0.25
        }
    val fleetHealth =
        if (items.isNotEmpty()) {
            items.map { it.pressureRemaining }.average()
        } else {
            1.0
        }
    val statusColor =
        when {
            hasUrgent -> AuroraColors.warning
            fleetHealth < 0.5 -> AuroraColors.amber
            else -> AuroraColors.success
        }
    val urgentCount = items.count { it.pressureRemaining < 0.25 }
    val providerWord = if (items.size == 1) "provider" else "providers"
    val fleetSubtitle =
        if (hasUrgent) {
            "${items.size} $providerWord · $urgentCount under pressure"
        } else {
            "${items.size} $providerWord · all healthy"
        }
    return QuotaFleetMeta(
        fleetHealth = fleetHealth,
        statusColor = statusColor,
        fleetSubtitle = fleetSubtitle,
    )
}

private data class QuotaPulseJiggleListState(
    val providerOrder: List<AgentProvider>,
    val visibleProviders: Set<AgentProvider>,
    val snapshots: List<ProviderQuotaSnapshot>,
    val prefs: QuotaPreferences,
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val percentageDisplayMode: String,
)

@Composable
private fun QuotaPulseJigglingList(state: QuotaPulseJiggleListState) {
    val orderedProviders = state.providerOrder.filter { state.visibleProviders.contains(it) }
    Column {
        orderedProviders.forEachIndexed { pIdx, provider ->
            JigglingProviderRow(
                model =
                JigglingProviderRowModel(
                    provider = provider,
                    snapshots = state.snapshots.filter {
                        AgentProvider.fromKey(it.providerId) == provider ||
                            AgentProvider.fromKey(it.provider) == provider
                    },
                    prefs = state.prefs,
                    index = pIdx,
                    total = orderedProviders.size,
                    hiddenBuckets = state.hiddenBuckets,
                    bucketOrders = state.bucketOrders,
                    providerOrder = state.providerOrder,
                    percentageDisplayMode = state.percentageDisplayMode,
                ),
            )
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun QuotaPulseDefaultBody(
    items: List<com.openburnbar.ui.burn.QuotaRingItem>,
    fleetMeta: QuotaFleetMeta,
    onSelect: (String) -> Unit,
    onOpenBurn: () -> Unit,
) {
    QuotaPulseFleetHero(
        fleetHealth = fleetMeta.fleetHealth,
        statusColor = fleetMeta.statusColor,
        fleetSubtitle = fleetMeta.fleetSubtitle,
    )
    Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
    Divider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
    Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
    QuotaPulseProviderList(items = items, onSelect = onSelect, onOpenBurn = onOpenBurn)
}
