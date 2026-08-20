package com.openburnbar.ui.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.io.File

/**
 * ACTION_SEND is an Activity. Copy the grantor's URI into durable app storage
 * before returning; temporary share URIs die with the grantor. Enqueue the
 * full begin→PUT→compose→finalize pipeline on WorkManager so compose cannot
 * die with the activity.
 */
class BurnbarShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent?.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
        if (uri != null) {
            val dest = File(filesDir, "share-inbox/${System.currentTimeMillis()}-${uri.lastPathSegment ?: "file"}")
            dest.parentFile?.mkdirs()
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            if (dest.isFile && dest.length() > 0) {
                val request =
                    OneTimeWorkRequestBuilder<BurnbarShareUploadWorker>()
                        .setInputData(
                            Data.Builder()
                                .putString(BurnbarShareUploadWorker.KEY_FILE_PATH, dest.absolutePath)
                                .build(),
                        )
                        .build()
                WorkManager.getInstance(applicationContext).enqueue(request)
            }
        }
        finish()
    }
}
