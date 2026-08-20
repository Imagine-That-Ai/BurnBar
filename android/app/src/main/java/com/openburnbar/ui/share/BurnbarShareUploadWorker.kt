package com.openburnbar.ui.share

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.media.BurnbarAttachmentUploadClient
import java.io.File

/** Durable begin→PUT→compose→finalize for ACTION_SEND copies. Sole begin owner. */
class BurnbarShareUploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        setForeground(createForegroundInfo())
        val path = inputData.getString(KEY_FILE_PATH) ?: return Result.failure()
        val file = File(path)
        val inbox = BurnbarShareInboxProcessor.inboxDirectory(applicationContext)
        if (!BurnbarShareInboxProcessor.isContained(file, inbox)) return Result.failure()
        if (!file.isFile) return Result.success()
        val deviceId = AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
        return runCatching {
            val outcome =
                BurnbarShareInboxProcessor.uploadOnce(
                    file = file,
                    deviceId = deviceId,
                    forceSteal = true,
                ) { dest, id ->
                    BurnbarAttachmentUploadClient().uploadFile(applicationContext, dest, id)
                }
            when (outcome) {
                BurnbarShareInboxProcessor.UploadOnceResult.Uploaded,
                BurnbarShareInboxProcessor.UploadOnceResult.Missing,
                -> Result.success()
                BurnbarShareInboxProcessor.UploadOnceResult.LockedFresh,
                -> Result.retry()
            }
        }.getOrElse { Result.retry() }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = createForegroundInfo()

    private fun createForegroundInfo(): ForegroundInfo {
        val notification =
            NotificationCompat.Builder(applicationContext, "burnbar-transfers")
                .setContentTitle("Uploading shared file")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build()
        return if (Build.VERSION.SDK_INT >= 34) {
            ForegroundInfo(4102, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(4102, notification)
        }
    }

    companion object {
        const val KEY_FILE_PATH = "filePath"
    }
}
