package com.openburnbar.ui.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import java.io.File

/**
 * ACTION_SEND is an Activity. Copy the grantor's URI into durable app storage
 * before returning; temporary share URIs die with the grantor.
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
        }
        finish()
    }
}
