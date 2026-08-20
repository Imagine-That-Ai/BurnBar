package com.openburnbar.data.media

import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Shared PUT for BurnBar attachment signed part URLs — one wire shape for the
 * WorkManager retry path ([BurnbarAttachmentTransferWorker]) and the interactive
 * upload client ([BurnbarAttachmentUploadClient]), so headers, the
 * `x-goog-if-generation-match` create-only guard, and timeouts cannot drift
 * between them.
 */
internal object BurnbarSignedUrlPut {
    private const val CONNECT_TIMEOUT_MS = 30_000
    private const val READ_TIMEOUT_MS = 120_000
    private val HTTP_SUCCESS_RANGE = 200..299

    fun isSuccess(code: Int): Boolean = code in HTTP_SUCCESS_RANGE

    /** PUTs the file to the signed URL and returns the HTTP response code. */
    fun put(file: File, signedUrl: String): Int {
        val connection = URL(signedUrl).openConnection()
        if (connection !is HttpURLConnection) {
            error("signed URL did not open as HTTP")
        }
        connection.requestMethod = "PUT"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("Content-Length", file.length().toString())
        connection.setRequestProperty("x-goog-if-generation-match", "0")
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        file.inputStream().use { input ->
            connection.outputStream.use { output -> input.copyTo(output) }
        }
        val code = connection.responseCode
        connection.disconnect()
        return code
    }
}
