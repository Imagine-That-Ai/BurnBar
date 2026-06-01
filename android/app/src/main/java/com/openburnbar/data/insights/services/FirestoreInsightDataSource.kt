package com.openburnbar.data.insights.services

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.dedupeFresh

/**
 * Android-native data source that builds InsightDigest from
 * Firestore rollups and direct provider APIs.
 *
 * Fields that require macOS-only local data (useCaseHistogram,
 * agentFocusSignals, modelFocusSignals) are left empty.
 */
class FirestoreInsightDataSource(
    private val dashboardStore: DashboardStore? = null,
    private val quotaStore: QuotaStore? = null,
    private val repo: FirestoreRepository = FirestoreRepository(),
) : InsightDataSource {
    override suspend fun buildDigest(filter: InsightFilter): InsightDigest {
        return buildDigest(filter.window)
    }

    override suspend fun buildDigest(window: InsightTimeWindow): InsightDigest {
        val rollups = dashboardStore?.rollups?.value ?: repo.fetchRollups()
        val quotaSnapshots =
            quotaStore?.snapshots?.value?.takeIf { it.isNotEmpty() }
                ?: repo.fetchQuotaSnapshots().dedupeFresh()
        val modelBenchmarks = runCatching { repo.fetchModelBenchmarkSnapshots() }.getOrDefault(emptyList())
        val components = buildFirestoreDigestComponents(rollups, window, quotaSnapshots)
        return assembleFirestoreDigest(window, components, modelBenchmarks)
    }
}

