package com.openburnbar.data.media

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.core.app.NotificationCompat

/**
 * Short retryable parts stay on WorkManager. Multi-GB user-started transfers
 * must use UIDT; this worker only covers parts that finish in minutes.
 */
class BurnbarAttachmentTransferWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        setForeground(createForegroundInfo())
        return Result.success()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = createForegroundInfo()

    private fun createForegroundInfo(): ForegroundInfo {
        val notification =
            NotificationCompat.Builder(applicationContext, "burnbar-transfers")
                .setContentTitle("Uploading attachment")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build()
        return if (Build.VERSION.SDK_INT >= 34) {
            ForegroundInfo(4101, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(4101, notification)
        }
    }
}
