package com.openburnbar.data.media

import com.openburnbar.irohrelay.BlobTransferStats
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.irohrelay.IrohBlobBackend
import com.openburnbar.irohrelay.IrohBlobBackendError
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Transport-agnostic Mercury file transfer driver. 1:1 Kotlin port of
 * `MediaFileTransferService.swift` (OpenBurnBarMedia). Sits between the
 * `AndroidFileTransferService` adapter and the underlying
 * `IrohBlobBackend`. Holds no Android-specific imports — Android wiring
 * lives in the adapter.
 *
 * Responsibility split:
 *
 * - This service: bootstrap the blob node, hash + publish a local file
 *   (returning the ticket + manifest), fetch a peer's ticket into a
 *   destination path.
 * - Android adapter: drive the chat-stream side of the protocol — emit
 *   `media.blob.advertise` after a publish, dispatch incoming
 *   `media.blob.advertise` to a fetch, emit `media.blob.ack` after the
 *   transfer settles.
 */
class MediaFileTransferService(
    private val backend: IrohBlobBackend,
    private val configuration: Configuration,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    data class Configuration(
        val storeDirectory: File,
        val inboxDirectory: File,
        val secretKeyProvider: suspend () -> IrohSecretKeyMaterial,
        val relayURL: String? = null,
    )

    data class PublishResult(
        val manifest: HermesRealtimeRelayAttachmentManifest,
        val ticketText: String,
    )

    sealed class ServiceError(message: String) : RuntimeException(message) {
        object BackendUnavailable : ServiceError("Iroh blob backend is unavailable.")
        object NotBootstrapped : ServiceError("Mercury blob backend has not been bootstrapped yet.")
        data class PublishFailed(val detail: String) : ServiceError("Publish failed: $detail")
        data class FetchFailed(val detail: String) : ServiceError("Fetch failed: $detail")
        data class LocalFileMissing(val path: String) : ServiceError("Missing file: $path")
        data class InvalidTicket(val detail: String) : ServiceError("Invalid ticket: $detail")
    }

    private val mutex = Mutex()
    private var bootstrappedIdentity: IrohEndpointIdentity? = null
    private var inflightBootstrap: Deferred<IrohEndpointIdentity>? = null

    /** Idempotently bring up the blob endpoint. Concurrent callers reuse the same in-flight bootstrap. */
    suspend fun bootstrap(): IrohEndpointIdentity {
        bootstrappedIdentity?.let { return it }
        mutex.withLock {
            bootstrappedIdentity?.let { return it }
            val pending = inflightBootstrap
            if (pending != null) {
                return pending.await()
            }
            val deferred = scope.async {
                ensureDirectoryExists(configuration.storeDirectory)
                ensureDirectoryExists(configuration.inboxDirectory)
                val secret = configuration.secretKeyProvider()
                backend.bootstrap(
                    secret = secret.raw,
                    storeDirectoryPath = configuration.storeDirectory.absolutePath,
                    relayURL = configuration.relayURL,
                )
            }
            inflightBootstrap = deferred
            try {
                val identity = deferred.await()
                bootstrappedIdentity = identity
                return identity
            } finally {
                inflightBootstrap = null
            }
        }
    }

    /** Publish a local file as a content-addressed blob. */
    suspend fun publish(localFile: File, peerDeviceID: String?): PublishResult {
        if (!localFile.exists()) throw ServiceError.LocalFileMissing(localFile.absolutePath)
        bootstrap()

        val ticketText: String = try {
            backend.publishBlob(localFile.absolutePath)
        } catch (err: IrohBlobBackendError) {
            throw ServiceError.PublishFailed(err.message ?: err.javaClass.simpleName)
        }

        val mime = inferMime(localFile)
        val manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId = "att_" + UUID.randomUUID().toString().lowercase(),
            blobHash = ticketText,
            filename = localFile.name,
            mime = mime,
            size = localFile.length(),
            peerDeviceId = peerDeviceID,
            createdAt = isoDate(System.currentTimeMillis()),
        )
        return PublishResult(manifest = manifest, ticketText = ticketText)
    }

    /** Fetch a peer's blob into the inbox directory and return the destination URL + transfer stats. */
    suspend fun fetch(
        ticketText: String,
        manifest: HermesRealtimeRelayAttachmentManifest,
    ): Pair<File, BlobTransferStats> {
        bootstrap()
        val destination = inboxFile(manifest)
        val stats = try {
            backend.fetchBlob(ticketText = ticketText, destination = destination.absolutePath)
        } catch (err: IrohBlobBackendError) {
            throw ServiceError.FetchFailed(err.message ?: err.javaClass.simpleName)
        }
        return destination to stats
    }

    /** Tear down the underlying blob endpoint. Idempotent. */
    suspend fun shutdown() {
        mutex.withLock {
            bootstrappedIdentity = null
            inflightBootstrap?.cancel()
            inflightBootstrap = null
        }
        withContext(Dispatchers.IO) { backend.shutdown() }
    }

    private fun inboxFile(manifest: HermesRealtimeRelayAttachmentManifest): File {
        val ext = manifest.filename.substringAfterLast('.', missingDelimiterValue = "")
        val nameBase = manifest.blobHash.replace("/", "_")
        val fullName = if (ext.isNotBlank()) "$nameBase.$ext" else nameBase
        return File(configuration.inboxDirectory, fullName)
    }

    private fun ensureDirectoryExists(directory: File) {
        if (!directory.exists()) {
            if (!directory.mkdirs() && !directory.exists()) {
                throw ServiceError.BackendUnavailable
            }
        }
    }

    private fun isoDate(epochMillis: Long): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return formatter.format(Date(epochMillis))
    }

    private fun inferMime(file: File): String = when (file.extension.lowercase()) {
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "heic" -> "image/heic"
        "heif" -> "image/heif"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "pdf" -> "application/pdf"
        "txt", "log" -> "text/plain"
        "json" -> "application/json"
        "mov" -> "video/quicktime"
        "mp4" -> "video/mp4"
        else -> "application/octet-stream"
    }
}
