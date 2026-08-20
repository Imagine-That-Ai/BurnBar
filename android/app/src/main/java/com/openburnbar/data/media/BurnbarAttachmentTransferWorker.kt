package com.openburnbar.data.media

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import java.io.File

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
        val filePath = inputData.getString(KEY_FILE_PATH) ?: return Result.failure()
        val signedUrl = inputData.getString(KEY_SIGNED_URL) ?: return Result.failure()
        val file = File(filePath)
        if (!file.isFile) return Result.failure()
        return runCatching { putFile(file, signedUrl) }.fold(
            onSuccess = { if (it) Result.success() else Result.retry() },
            onFailure = { Result.retry() },
        )
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = createForegroundInfo()

    private fun putFile(file: File, signedUrl: String): Boolean = BurnbarSignedUrlPut.isSuccess(BurnbarSignedUrlPut.put(file, signedUrl))

    internal fun createForegroundInfo(): ForegroundInfo {
        val notification =
            NotificationCompat.Builder(applicationContext, "burnbar-transfers")
                .setContentTitle("Uploading attachment")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(TRANSFER_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(TRANSFER_NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val KEY_FILE_PATH = "filePath"
        const val KEY_SIGNED_URL = "signedUrl"

        private const val TRANSFER_NOTIFICATION_ID = 4101

        fun requiredForegroundServiceType(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
    }
}
