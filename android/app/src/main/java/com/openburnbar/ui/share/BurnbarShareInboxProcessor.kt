package com.openburnbar.ui.share

import android.content.Context
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.media.BurnbarAttachmentUploadClient
import java.io.File

/**
 * Single owner for ACTION_SEND leftovers: unique WorkManager jobs named by
 * inbox path. `.uploading` is an exclusive begin lock. Filenames are sanitized
 * so dest stays under share-inbox/.
 */
object BurnbarShareInboxProcessor {
    const val STALE_LOCK_MS = 30_000L

    enum class UploadOnceResult {
        Uploaded,
        LockedFresh,
        Missing,
    }

    fun inboxDirectory(context: Context): File = File(context.filesDir, "share-inbox")

    fun sanitizeFilename(raw: String?): String {
        var name = (raw ?: "file").replace("\u0000", "")
        name = name.replace('\\', '/')
        name = name.substringAfterLast('/')
        if (name.isBlank() || name == "." || name == "..") return "file"
        if (name.contains("..")) name = name.replace("..", "_")
        return name
    }

    fun containedDest(inbox: File, filename: String, timestampMillis: Long = System.currentTimeMillis()): File {
        inbox.mkdirs()
        val safe = sanitizeFilename(filename)
        val dest = File(inbox, "$timestampMillis-$safe").canonicalFile
        require(isContained(dest, inbox)) { "share dest escaped inbox" }
        return dest
    }

    fun isContained(file: File, inbox: File): Boolean {
        val root = inbox.canonicalFile
        val candidate = file.canonicalFile
        val prefix = if (root.path.endsWith(File.separator)) root.path else root.path + File.separator
        return candidate.path == root.path || candidate.path.startsWith(prefix)
    }

    fun uniqueWorkName(file: File): String = "burnbar-share-upload-${file.canonicalFile.absolutePath.hashCode().toUInt()}"

    fun pendingFiles(root: File): List<File> {
        val items = root.listFiles() ?: return emptyList()
        return items.filter { it.isFile && it.extension !in setOf("pending", "uploading", "failed", "done") }
    }

    fun pendingFiles(context: Context): List<File> = pendingFiles(inboxDirectory(context))

    fun lockFile(file: File): File = File(file.parentFile, "${file.name}.uploading")

    fun isStaleLock(lock: File, nowMs: Long = System.currentTimeMillis(), staleAfterMs: Long = STALE_LOCK_MS): Boolean {
        if (!lock.exists()) return true
        val modified = lock.lastModified()
        return modified <= 0L || nowMs - modified >= staleAfterMs
    }

    /**
     * Exclusive begin lock. Stale leftover locks (process death) are stolen.
     * [forceSteal] is for the unique WorkManager owner: this worker is the
     * only runner for the path, so a leftover lock is never a live peer.
     */
    fun tryAcquireUploadLock(file: File, nowMs: Long = System.currentTimeMillis(), staleAfterMs: Long = STALE_LOCK_MS, forceSteal: Boolean = false): Boolean {
        val lock = lockFile(file)
        if (lock.createNewFile()) return true
        if (!forceSteal && !isStaleLock(lock, nowMs, staleAfterMs)) return false
        lock.delete()
        return lock.createNewFile()
    }

    fun releaseUploadLock(file: File) {
        lockFile(file).delete()
    }

    fun consume(file: File) {
        if (file.exists()) file.delete()
        releaseUploadLock(file)
    }

    fun isPermanentFailure(error: Throwable): Boolean {
        val text = (error.message ?: "").lowercase()
        return text.contains("missing") || text.contains("not found") || text.contains("invalid")
    }

    suspend fun uploadOnce(
        file: File,
        deviceId: String,
        forceSteal: Boolean = false,
        nowMs: Long = System.currentTimeMillis(),
        staleAfterMs: Long = STALE_LOCK_MS,
        upload: suspend (File, String) -> Unit,
    ): UploadOnceResult {
        if (!file.isFile) return UploadOnceResult.Missing
        if (!tryAcquireUploadLock(file, nowMs = nowMs, staleAfterMs = staleAfterMs, forceSteal = forceSteal)) {
            return UploadOnceResult.LockedFresh
        }
        try {
            upload(file, deviceId)
            consume(file)
            return UploadOnceResult.Uploaded
        } catch (error: Exception) {
            if (isPermanentFailure(error)) {
                consume(file)
                throw error
            }
            throw error
        } finally {
            releaseUploadLock(file)
        }
    }

    fun enqueueUnique(context: Context, file: File, policy: ExistingWorkPolicy = ExistingWorkPolicy.KEEP) {
        if (!file.isFile || file.length() <= 0) return
        if (!isContained(file, inboxDirectory(context))) return
        val request =
            OneTimeWorkRequestBuilder<BurnbarShareUploadWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(BurnbarShareUploadWorker.KEY_FILE_PATH, file.absolutePath)
                        .build(),
                )
                .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            uniqueWorkName(file),
            policy,
            request,
        )
    }

    fun enqueuePending(context: Context) {
        // REPLACE leftover unique work so a prior skip-success cannot pin KEEP forever.
        for (file in pendingFiles(context)) {
            enqueueUnique(context, file, ExistingWorkPolicy.REPLACE)
        }
    }

    suspend fun processPending(root: File, deviceId: String, upload: suspend (File, String) -> Unit) {
        for (file in pendingFiles(root)) {
            runCatching { uploadOnce(file, deviceId, upload = upload) }
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
}
