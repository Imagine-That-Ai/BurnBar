package com.openburnbar.data.media

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

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

    private fun putFile(file: File, signedUrl: String): Boolean {
        val connection = URL(signedUrl).openConnection() as HttpURLConnection
        connection.requestMethod = "PUT"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("Content-Length", file.length().toString())
        connection.setRequestProperty("x-goog-if-generation-match", "0")
        connection.connectTimeout = 30_000
        connection.readTimeout = 120_000
        file.inputStream().use { input ->
            connection.outputStream.use { output -> input.copyTo(output) }
        }
        val code = connection.responseCode
        connection.disconnect()
        return code in 200..299
    }

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

    companion object {
        const val KEY_FILE_PATH = "filePath"
        const val KEY_SIGNED_URL = "signedUrl"
    }
}
