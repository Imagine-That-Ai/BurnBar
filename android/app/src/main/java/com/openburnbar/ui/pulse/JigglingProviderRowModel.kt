package com.openburnbar.ui.pulse

import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.stores.QuotaPreferences

internal data class JigglingProviderRowModel(
    val provider: AgentProvider,
    val snapshots: List<ProviderQuotaSnapshot>,
    val prefs: QuotaPreferences,
    val index: Int,
    val total: Int,
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val providerOrder: List<AgentProvider>,
    val percentageDisplayMode: String,
)
