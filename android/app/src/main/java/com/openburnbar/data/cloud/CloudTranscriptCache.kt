package com.openburnbar.data.cloud

import android.content.Context
import com.openburnbar.BurnBarApplication
import java.io.File
import java.security.MessageDigest
import java.util.Locale

data class CloudTranscriptCacheSnapshot(
    val usageBytes: Long,
    val maxBytes: Long,
) {
    val isDisabled: Boolean get() = maxBytes <= 0L
    val isFull: Boolean get() = !isDisabled && usageBytes >= maxBytes
}

object CloudTranscriptCacheSettings {
    const val DEFAULT_MAX_MEGABYTES = 250
    const val MAXIMUM_MEGABYTES = 2_048
    const val BYTES_PER_MEGABYTE = 1_024L * 1_024L

    private const val PREFS_NAME = "streams_transcript_cache"
    private const val MAX_MEGABYTES_KEY = "max_megabytes_v1"

    fun maxMegabytes(context: Context = BurnBarApplication.appContext): Int {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return clampMegabytes(prefs.getInt(MAX_MEGABYTES_KEY, DEFAULT_MAX_MEGABYTES))
    }

    fun setMaxMegabytes(value: Int, context: Context = BurnBarApplication.appContext) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putInt(MAX_MEGABYTES_KEY, clampMegabytes(value)).apply()
    }

    fun maxBytes(context: Context = BurnBarApplication.appContext): Long =
        maxMegabytes(context).toLong() * BYTES_PER_MEGABYTE

    fun clampMegabytes(value: Int): Int =
        value.coerceIn(0, MAXIMUM_MEGABYTES)

    fun formatBytes(bytes: Long): String {
        val safeBytes = bytes.coerceAtLeast(0L)
        val megabytes = safeBytes.toDouble() / BYTES_PER_MEGABYTE.toDouble()
        return if (megabytes >= 1_024.0) {
            String.format(Locale.US, "%.1f GB", megabytes / 1_024.0)
        } else {
            String.format(Locale.US, "%.0f MB", megabytes)
        }
    }
}

object CloudTranscriptCache {
    private const val CACHE_DIR = "OpenBurnBarCloudTranscripts"

    @Synchronized
    fun cachedEnvelopeBytes(
        storagePath: String,
        bodyHash: String,
        context: Context = BurnBarApplication.appContext,
    ): ByteArray? {
        if (CloudTranscriptCacheSettings.maxBytes(context) <= 0L) return null
        val file = blobFile(context, storagePath, bodyHash)
        if (!file.exists()) return null
        return runCatching {
            val bytes = file.readBytes()
            file.setLastModified(System.currentTimeMillis())
            bytes
        }.getOrNull()
    }

    @Synchronized
    fun storeEnvelopeBytes(
        storagePath: String,
        bodyHash: String,
        bytes: ByteArray,
        context: Context = BurnBarApplication.appContext,
    ) {
        val maxBytes = CloudTranscriptCacheSettings.maxBytes(context)
        if (maxBytes <= 0L) {
            clear(context)
            return
        }
        if (bytes.size.toLong() > maxBytes) return

        val dir = directory(context)
        dir.mkdirs()
        val destination = blobFile(context, storagePath, bodyHash)
        val tmp = File(dir, "${destination.name}.tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(destination)) {
            tmp.copyTo(destination, overwrite = true)
            tmp.delete()
        }
        destination.setLastModified(System.currentTimeMillis())
        trimToLimit(context)
    }

    @Synchronized
    fun remove(
        storagePath: String,
        bodyHash: String,
        context: Context = BurnBarApplication.appContext,
    ) {
        blobFile(context, storagePath, bodyHash).delete()
    }

    @Synchronized
    fun clear(context: Context = BurnBarApplication.appContext) {
        val dir = directory(context)
        if (dir.exists()) dir.deleteRecursively()
        dir.mkdirs()
    }

    @Synchronized
    fun trimToLimit(context: Context = BurnBarApplication.appContext) {
        val maxBytes = CloudTranscriptCacheSettings.maxBytes(context)
        if (maxBytes <= 0L) {
            clear(context)
            return
        }
        val files = cacheFiles(context).sortedBy { it.lastModified() }.toMutableList()
        var usage = files.sumOf { it.length() }
        while (usage > maxBytes && files.isNotEmpty()) {
            val file = files.removeAt(0)
            val length = file.length()
            if (file.delete()) usage -= length
        }
    }

    @Synchronized
    fun snapshot(context: Context = BurnBarApplication.appContext): CloudTranscriptCacheSnapshot {
        trimToLimit(context)
        return CloudTranscriptCacheSnapshot(
            usageBytes = cacheFiles(context).sumOf { it.length() },
            maxBytes = CloudTranscriptCacheSettings.maxBytes(context),
        )
    }

    private fun directory(context: Context): File =
        File(context.cacheDir, CACHE_DIR)

    private fun blobFile(context: Context, storagePath: String, bodyHash: String): File =
        File(directory(context), "${cacheKey(storagePath, bodyHash)}.json")

    private fun cacheFiles(context: Context): List<File> =
        directory(context).listFiles()?.filter { it.isFile && it.extension == "json" } ?: emptyList()

    private fun cacheKey(storagePath: String, bodyHash: String): String =
        sha256Hex("$storagePath\n$bodyHash".toByteArray(Charsets.UTF_8))

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
}
