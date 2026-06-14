package com.openburnbar.data.cloud

import android.content.Context
import java.io.File
import java.security.MessageDigest

internal object CloudTranscriptCacheStorage {
    private const val CACHE_DIR = "OpenBurnBarCloudTranscripts"
    private const val BYTE_MASK = 0xff

    fun directory(context: Context): File = File(context.cacheDir, CACHE_DIR)

    fun blobFile(context: Context, storagePath: String, bodyHash: String, bodyHashVersion: Int): File =
        File(directory(context), "${cacheKey(storagePath, bodyHash, bodyHashVersion)}.json")

    fun cacheFiles(context: Context): List<File> = directory(context).listFiles()?.filter { it.isFile && it.extension == "json" } ?: emptyList()

    fun cacheKey(storagePath: String, bodyHash: String, bodyHashVersion: Int): String =
        sha256Hex("$storagePath\n$bodyHash\n$bodyHashVersion".toByteArray(Charsets.UTF_8))

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
        "%02x".format(it.toInt() and BYTE_MASK)
    }
}
