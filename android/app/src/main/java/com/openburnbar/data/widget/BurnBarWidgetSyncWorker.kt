package com.openburnbar.data.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.updateAll
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.widget.BurnBarLargeWidget
import com.openburnbar.ui.widget.BurnBarLockCircularWidget
import com.openburnbar.ui.widget.BurnBarLockRectangularWidget
import com.openburnbar.ui.widget.BurnBarMediumWidget
import com.openburnbar.ui.widget.BurnBarSmallWidget
import java.util.concurrent.TimeUnit

/**
 * Hydrates the widget snapshot from Firestore on a 15-minute cadence (the
 * minimum WorkManager periodic interval — matches iOS's hard-coded refresh
 * exactly). The main app also invokes [requestImmediate] after each rollup
 * refresh so widgets catch up faster than 15 min when the app is open.
 *
 * On success: writes the snapshot via [BurnBarWidgetSnapshotStore] and calls
 * `updateAll` on every Glance receiver so pinned widgets re-render right
 * away.
 */
class BurnBarWidgetSyncWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        if (uid == null) {
            // Not signed in — leave the placeholder showing.
            return Result.success()
        }

        val repo = FirestoreRepository()
        val rollups = runCatching { repo.fetchRollups() }.getOrNull() ?: UsageRollups()
        val snap = buildSnapshot(rollups)

        BurnBarWidgetSnapshotStore.write(applicationContext, snap)
        refreshAllReceivers(applicationContext)
        return Result.success()
    }

    private fun buildSnapshot(rollups: UsageRollups): BurnBarWidgetSnapshot {
        val topProviders = rollups.providerSummaries
            .sortedByDescending { it.totalTokens }
            .take(3)
        val names = topProviders.map { p ->
            AgentProvider.fromKey(p.provider)?.displayName ?: p.provider
        }
        val tokens = topProviders.map { it.totalTokens }
        val models = rollups.modelSummaries
            .sortedByDescending { it.totalCost }
            .take(3)
            .map { it.accountLabel.ifBlank { it.provider } }
        val daily = rollups.dailyPoints.entries
            .sortedBy { it.key }
            .takeLast(7)
            .map { it.value }
        return BurnBarWidgetSnapshot(
            heroTotalCost = rollups.today,
            heroTotalTokens = rollups.todayTokens,
            heroTotalRequests = (rollups.totals["requests"] ?: 0.0).toInt(),
            topProviders = names,
            topProviderTokens = tokens,
            topModels = models,
            dailyPoints = daily,
            windowKey = "today",
            lastSyncMs = System.currentTimeMillis()
        )
    }

    companion object {
        const val UNIQUE_PERIODIC = "burnbar.widget.sync.periodic"
        const val UNIQUE_IMMEDIATE = "burnbar.widget.sync.immediate"

        /** Schedule the 15-min periodic job. Idempotent — replaces on conflict. */
        fun enqueuePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<BurnBarWidgetSyncWorker>(
                15, TimeUnit.MINUTES
            )
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_PERIODIC,
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
        }

        /** Kick a one-shot refresh immediately. Used by DashboardStore after a rollup load. */
        fun requestImmediate(context: Context) {
            val request = OneTimeWorkRequestBuilder<BurnBarWidgetSyncWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_IMMEDIATE,
                ExistingWorkPolicy.REPLACE,
                request
            )
        }

        /** Push the latest snapshot into every Glance widget surface. */
        suspend fun refreshAllReceivers(context: Context) {
            val widgets: List<GlanceAppWidget> = listOf(
                BurnBarSmallWidget,
                BurnBarMediumWidget,
                BurnBarLargeWidget,
                BurnBarLockCircularWidget,
                BurnBarLockRectangularWidget
            )
            for (widget in widgets) {
                runCatching { widget.updateAll(context) }
            }
        }
    }
}
