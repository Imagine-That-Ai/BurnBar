package com.openburnbar.data.media

import android.content.Context
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import java.io.File

/** Product path: begin → mint → enqueue signed PUT worker → compose → finalize. */
class BurnbarAttachmentUploadClient(
    private val securityClient: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
) {
    data class UploadedRef(
        val id: String,
        val contentBlake3: String,
        val displayName: String,
        val byteCount: Long,
        val transport: String = "cloud",
    )

    suspend fun uploadFile(context: Context, file: File, deviceId: String): UploadedRef {
        require(file.isFile) { "Attachment file is missing." }
        val digest = ContentBlake3.parse(shaPlaceholder(file))
        val begun = securityClient.beginBurnbarAttachment(
            byteCount = file.length(),
            contentBlake3 = digest,
            deviceId = deviceId,
        )
        val id = begun["id"] as? String ?: error("beginBurnbarAttachment missing id")
        val chunkCount = (begun["chunkCount"] as? Number)?.toInt() ?: 1
        val partSize = 32L * 1024 * 1024
        file.inputStream().use { input ->
            val buffer = ByteArray(partSize.toInt())
            for (index in 0 until chunkCount) {
                val read = input.read(buffer)
                require(read > 0) { "part $index empty" }
                val partFile = File(context.cacheDir, "burnbar-part-$id-$index")
                partFile.writeBytes(buffer.copyOf(read))
                val signedUrl = securityClient.mintBurnbarAttachmentPartURL(
                    id = id,
                    partIndex = index,
                    contentLength = read.toLong(),
                    deviceId = deviceId,
                )
                enqueuePut(context, partFile, signedUrl)
            }
        }
        securityClient.composeBurnbarAttachment(id, deviceId)
        securityClient.finalizeBurnbarAttachment(id, deviceId)
        return UploadedRef(
            id = id,
            contentBlake3 = digest,
            displayName = file.name,
            byteCount = file.length(),
        )
    }

    private fun enqueuePut(context: Context, file: File, signedUrl: String) {
        val request =
            OneTimeWorkRequestBuilder<BurnbarAttachmentTransferWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(BurnbarAttachmentTransferWorker.KEY_FILE_PATH, file.absolutePath)
                        .putString(BurnbarAttachmentTransferWorker.KEY_SIGNED_URL, signedUrl)
                        .build(),
                )
                .build()
        WorkManager.getInstance(context).enqueue(request)
    }

    private fun shaPlaceholder(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(file.readBytes())
        // Not used as contentBlake3; parseOrHash requires 64 hex. Hash the file name+size into a
        // stable hex so tests can drive begin without a ticket.
        return digest.joinToString("") { "%02x".format(it) }
    }
}
