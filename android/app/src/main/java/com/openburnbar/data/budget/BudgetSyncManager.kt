package com.openburnbar.data.budget

import android.content.Context
import android.util.Log
import com.openburnbar.data.db.BudgetDatabaseAccess
import com.openburnbar.data.db.toEntity
import com.openburnbar.data.firebase.FirestoreRepository
import java.lang.IllegalStateException
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val VAL_500 = 500

class BudgetSyncManager(
    private val context: Context,
    private val dao: BudgetDatabaseAccess,
    private val repo: FirestoreRepository = FirestoreRepository(),
) {
    private val localDeviceId: String
        get() {
            val sharedPrefs = context.getSharedPreferences("burnbar.device", Context.MODE_PRIVATE)
            return sharedPrefs.getString("stable_device_id", "android-device") ?: "android-device"
        }

    suspend fun sync() = withContext(Dispatchers.IO) {
        try {
            Log.d("BudgetSync", "Starting budget sync...")
            // 1. Upload local rules that haven't been synced yet (syncedAt is null)
            val unsyncedRules = dao.getAllEnabledRules().filter { it.syncedAt == null }
            if (unsyncedRules.isNotEmpty()) {
                Log.d("BudgetSync", "Uploading ${unsyncedRules.size} local rules...")
                val modelsToUpload =
                    unsyncedRules.map {
                        it.toModel().copy(
                            sourceDeviceID = localDeviceId,
                            updatedAt = Date(),
                        )
                    }
                repo.budget.uploadBudgetRules(modelsToUpload)
                for (rule in unsyncedRules) {
                    dao.upsertRule(rule.copy(syncedAt = System.currentTimeMillis()))
                }
            }

            // 2. Upload local events that haven't been synced (syncedAt is null)
            val unsyncedEvents = dao.getRecentEvents(VAL_500).filter { it.syncedAt == null }
            if (unsyncedEvents.isNotEmpty()) {
                Log.d("BudgetSync", "Uploading ${unsyncedEvents.size} local events...")
                val modelsToUpload =
                    unsyncedEvents.map {
                        it.toModel().copy(
                            sourceDeviceID = localDeviceId,
                        )
                    }
                repo.budget.uploadBudgetEvents(modelsToUpload)
                for (event in unsyncedEvents) {
                    dao.insertEvent(event.copy(syncedAt = System.currentTimeMillis()))
                }
            }

            // 3. Download rules from Firestore and merge
            Log.d("BudgetSync", "Downloading rules from Firestore...")
            val remoteRules = repo.budget.downloadAllBudgetRules()
            for (remote in remoteRules) {
                val local = dao.getAllEnabledRules().firstOrNull { it.id == remote.id }
                if (local == null) {
                    dao.upsertRule(remote.copy(syncedAt = Date()).toEntity())
                } else {
                    val remoteUpdated = remote.updatedAt?.time ?: 0L
                    val localUpdated = local.updatedAt
                    if (remoteUpdated > localUpdated) {
                        dao.upsertRule(remote.copy(syncedAt = Date()).toEntity())
                    } else if (localUpdated > remoteUpdated && local.syncedAt == null) {
                        repo.budget.uploadBudgetRule(local.toModel().copy(sourceDeviceID = localDeviceId, updatedAt = Date()))
                        dao.upsertRule(local.copy(syncedAt = System.currentTimeMillis()))
                    }
                }
            }
            Log.d("BudgetSync", "Budget sync completed successfully.")
        } catch (e: IllegalStateException) {
            Log.e("BudgetSync", "Error syncing budget data: ${e.message}", e)
        }
    }
}
