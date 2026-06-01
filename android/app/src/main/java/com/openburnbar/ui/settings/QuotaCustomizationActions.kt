package com.openburnbar.ui.settings

import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket

internal data class QuotaCustomizationActions(
    val onBack: () -> Unit,
    val onPercentageDisplayMode: (String) -> Unit,
    val onVisibleProviders: (Set<AgentProvider>) -> Unit,
    val onProviderOrder: (List<AgentProvider>) -> Unit,
    val onHiddenBuckets: (Set<String>) -> Unit,
    val onBucketOrders: (Map<String, List<String>>) -> Unit,
    val onExpandedProviderKey: (String?) -> Unit,
    val onHaptic: () -> Unit,
)

internal data class QuotaCustomizationUiState(
    val mockBucket: QuotaBucket,
    val percentageDisplayMode: String,
    val providerOrder: List<AgentProvider>,
    val visibleProviders: Set<AgentProvider>,
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val snapshots: List<ProviderQuotaSnapshot>,
    val expandedProviderKey: String?,
)

internal data class QuotaCustomizationProviderCardContext(
    val provider: AgentProvider,
    val index: Int,
    val providerCount: Int,
    val isVisible: Boolean,
    val isExpanded: Boolean,
    val matchingSnapshot: ProviderQuotaSnapshot?,
)
