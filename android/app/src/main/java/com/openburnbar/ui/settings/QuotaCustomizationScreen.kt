package com.openburnbar.ui.settings

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore

@Composable
fun QuotaCustomizationScreen(onBack: () -> Unit, quotaStore: QuotaStore = viewModel()) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val isDark = isSystemInDarkTheme()

    val prefs = remember(context) { QuotaPreferences.get(context) }
    val providerOrder by prefs.providerOrder.collectAsState()
    val visibleProviders by prefs.visibleProviders.collectAsState()
    val hiddenBuckets by prefs.hiddenBuckets.collectAsState()
    val bucketOrders by prefs.bucketOrders.collectAsState()
    val percentageDisplayMode by prefs.percentageDisplayMode.collectAsState()

    val snapshots by quotaStore.snapshots.collectAsState()
    var expandedProviderKey by remember { mutableStateOf<String?>(null) }

    val mockBucket =
        remember {
            QuotaBucket(
                name = "Included Usage",
                used = 12.0,
                limit = 15.0,
                remaining = 3.0,
                window = "monthly",
                meta = mapOf("unit" to "currency", "label" to "Included Usage"),
            )
        }

    val actions =
        QuotaCustomizationActions(
            onBack = onBack,
            onPercentageDisplayMode = prefs::setPercentageDisplayMode,
            onVisibleProviders = prefs::setVisibleProviders,
            onProviderOrder = prefs::setProviderOrder,
            onHiddenBuckets = prefs::setHiddenBuckets,
            onBucketOrders = prefs::setBucketOrders,
            onExpandedProviderKey = { expandedProviderKey = it },
            onHaptic = { haptic.performHapticFeedback(HapticFeedbackType.LongPress) },
        )

    Box(modifier = Modifier.fillMaxSize()) {
        QuotaCustomizationScaffold(isDark = isDark, actions = actions) {
            QuotaCustomizationContent(
                state =
                QuotaCustomizationUiState(
                    mockBucket = mockBucket,
                    percentageDisplayMode = percentageDisplayMode,
                    providerOrder = providerOrder,
                    visibleProviders = visibleProviders,
                    hiddenBuckets = hiddenBuckets,
                    bucketOrders = bucketOrders,
                    snapshots = snapshots,
                    expandedProviderKey = expandedProviderKey,
                ),
                actions = actions,
            )
        }
    }
}
