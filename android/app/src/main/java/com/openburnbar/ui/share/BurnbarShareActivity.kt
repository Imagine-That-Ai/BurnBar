package com.openburnbar.ui.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.media.BurnbarAttachmentUploadClient
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * ACTION_SEND is an Activity. Copy the grantor's URI into durable app storage
 * before returning; temporary share URIs die with the grantor. Then begin the
 * burnbar attachment upload on a background scope.
 */
class BurnbarShareActivity : ComponentActivity() {
    private val uploadScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent?.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
        if (uri != null) {
            val dest = File(filesDir, "share-inbox/${System.currentTimeMillis()}-${uri.lastPathSegment ?: "file"}")
            dest.parentFile?.mkdirs()
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            File(dest.parentFile, "${dest.name}.pending").writeText(dest.absolutePath)
            val copied = dest
            uploadScope.launch {
                val deviceId = AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
                runCatching {
                    BurnbarAttachmentUploadClient().uploadFile(this@BurnbarShareActivity, copied, deviceId)
                }
            }
        }
        finish()
    }
}
