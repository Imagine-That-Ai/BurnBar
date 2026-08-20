package com.openburnbar.ui.share

import android.content.Context
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.media.BurnbarAttachmentUploadClient
import java.io.File

/** Drain leftover ACTION_SEND copies after a process death. */
object BurnbarShareInboxProcessor {
    fun inboxDirectory(context: Context): File = File(context.filesDir, "share-inbox")

    fun pendingFiles(root: File): List<File> {
        val items = root.listFiles() ?: return emptyList()
        return items.filter { it.isFile && it.extension !in setOf("pending", "uploading", "failed", "done") }
    }

    fun pendingFiles(context: Context): List<File> = pendingFiles(inboxDirectory(context))

    suspend fun processPending(
        root: File,
        deviceId: String,
        upload: suspend (File, String) -> Unit,
    ) {
        for (file in pendingFiles(root)) {
            try {
                upload(file, deviceId)
                consume(file)
            } catch (error: Exception) {
                if (isPermanentFailure(error)) consume(file)
            }
        }
    }

    suspend fun processPending(
        context: Context,
        upload: suspend (File, String) -> Unit = { file, deviceId ->
            BurnbarAttachmentUploadClient().uploadFile(context, file, deviceId)
            Unit
        },
    ) {
        val deviceId = AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
        processPending(inboxDirectory(context), deviceId, upload)
    }

    fun isPermanentFailure(error: Throwable): Boolean {
        val text = (error.message ?: "").lowercase()
        return text.contains("missing") || text.contains("not found") || text.contains("invalid")
    }

    fun consume(file: File) {
        if (file.exists()) file.delete()
    }
}
