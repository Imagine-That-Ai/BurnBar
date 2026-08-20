package com.openburnbar.data.media

import android.content.Context
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import com.openburnbar.data.computeruse.beginBurnbarAttachment
import com.openburnbar.data.computeruse.composeBurnbarAttachment
import com.openburnbar.data.computeruse.finalizeBurnbarAttachment
import com.openburnbar.data.computeruse.mintBurnbarAttachmentPartURL
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** Product path: stream FileSeal chunks, await each PUT, then compose/finalize. */
class BurnbarAttachmentUploadClient(
    private val securityClient: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
) {
    data class UploadedRef(
        val id: String,
        val contentBlake3: String,
        val displayName: String,
        val byteCount: Long,
        val transport: String = "cloud",
        val contentKeyBase64: String? = null,
    )

    suspend fun uploadFile(context: Context, file: File, deviceId: String): UploadedRef {
        require(file.isFile) { "Attachment file is missing." }
        val digest = ContentBlake3.hashFile(file)
        val begun = securityClient.beginBurnbarAttachment(
            byteCount = file.length(),
            contentBlake3 = digest,
            deviceId = deviceId,
        )
        val id = begun["id"] as? String ?: error("beginBurnbarAttachment missing id")
        val chunkCount = (begun["chunkCount"] as? Number)?.toInt() ?: 1
        val contentKey = FileSealAEAD.mintContentKey()
        val header = FileSealAEAD.Header(
            attachmentId = id,
            totalChunks = chunkCount,
            plaintextSize = file.length(),
            contentBlake3 = digest,
        )
        FileInputStream(file).use { input ->
            val buffer = ByteArray(FileSealAEAD.CHUNK_PLAINTEXT_BYTES)
            for (index in 0 until chunkCount) {
                val read = input.read(buffer)
                require(read > 0) { "part $index empty" }
                val chunk = buffer.copyOf(read)
                val nonce = FileSealAEAD.mintNonce()
                val sealed = FileSealAEAD.sealChunk(chunk, contentKey, header, index.toLong(), nonce)
                val partFile = File(context.cacheDir, "burnbar-part-$id-$index")
                FileOutputStream(partFile).use { out ->
                    out.write(nonce)
                    out.write(sealed.first)
                    out.write(sealed.second)
                }
                val signedUrl = securityClient.mintBurnbarAttachmentPartURL(
                    id = id,
                    partIndex = index,
                    contentLength = partFile.length(),
                    deviceId = deviceId,
                )
                putAwaiting(partFile, signedUrl)
            }
        }
        securityClient.composeBurnbarAttachment(id, deviceId)
        securityClient.finalizeBurnbarAttachment(id, deviceId)
        return UploadedRef(
            id = id,
            contentBlake3 = digest,
            displayName = file.name,
            byteCount = file.length(),
            contentKeyBase64 = android.util.Base64.encodeToString(contentKey, android.util.Base64.NO_WRAP),
        )
    }

    private fun putAwaiting(file: File, signedUrl: String) {
        val code = BurnbarSignedUrlPut.put(file, signedUrl)
        require(BurnbarSignedUrlPut.isSuccess(code)) { "Attachment part PUT failed: $code" }
    }
}
