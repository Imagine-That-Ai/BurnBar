package com.openburnbar.data.media

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.IrohEndpointIdentity
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Android-side file transfer driver. 1:1 port of `iOSFileTransferService`
 * (Swift). Receive flow:
 *   1. Android sees `media.blob.advertise` on the active chat response
 *      stream (the chat connection Android dialed to Mac) **or** on the
 *      persistent media-control stream owned by `MediaControlStreamCoordinator`.
 *   2. `HermesIrohRelayTransport` (or the control coordinator) routes
 *      the frame to `handleAdvertise(frame, ackSender)`.
 *   3. Service runs `MediaFileTransferService.fetch` to download the blob
 *      into the per-blob inbox.
 *   4. Service emits `media.blob.ack` back on the same stream.
 *   5. UI surfaces (`AttachmentBubble`) read the `lastReceivedAttachment`
 *      flow to render the attachment row.
 *
 * Send flow: `sendFile(uri, uid, connectionId, peerDeviceId)` materialises
 * the content URI to a cache File, publishes the blob, then dispatches
 * an advertise frame either via an explicit override (tests) or the
 * persistent media control coordinator (production). Never silently
 * drops a user-initiated send — bubbles up `Failure.dispatchUnavailable`
 * when no transport is wired.
 */
class AndroidFileTransferService(
    private val appContext: Context,
    private val service: MediaFileTransferService,
    private val settingsProvider: () -> Boolean,
    private val analytics: MediaAnalyticsLogger? = null,
) {
    sealed class Failure(message: String) : RuntimeException(message) {
        object BackendUnavailable : Failure("Mercury file transfer is unavailable on this build.")

        data class FileMissing(val path: String) : Failure("File missing: $path")

        data class PublishFailed(val detail: String) : Failure("Publish failed: $detail")

        data class FetchFailed(val detail: String) : Failure("Fetch failed: $detail")

        object DispatchUnavailable : Failure("No active iroh stream is available.")

        object SettingDisabled : Failure("media_blob_transfer_enabled is off.")
    }

    fun interface AdvertiseSender {
        suspend fun send(frame: HermesRealtimeRelayFrame)
    }

    data class ReceivedAttachment(
        val id: String,
        val manifest: HermesRealtimeRelayAttachmentManifest,
        val destinationFile: File,
    )

    private val mutex = Mutex()
    private var controlCoordinator: MediaControlStreamCoordinator? = null

    private val _lastError = MutableStateFlow<Failure?>(null)
    val lastError: StateFlow<Failure?> = _lastError.asStateFlow()

    private val _inFlightCount = MutableStateFlow(0)
    val inFlightCount: StateFlow<Int> = _inFlightCount.asStateFlow()

    private val _lastReceivedAttachment = MutableStateFlow<ReceivedAttachment?>(null)
    val lastReceivedAttachment: StateFlow<ReceivedAttachment?> = _lastReceivedAttachment.asStateFlow()

    private val _lastSentManifestID = MutableStateFlow<String?>(null)
    val lastSentManifestID: StateFlow<String?> = _lastSentManifestID.asStateFlow()

    suspend fun attachControlStream(coordinator: MediaControlStreamCoordinator) {
        mutex.withLock { controlCoordinator = coordinator }
    }

    suspend fun detachControlStream() {
        mutex.withLock {
            controlCoordinator?.stop()
            controlCoordinator = null
        }
    }

    suspend fun bootstrapBlobEndpoint(): IrohEndpointIdentity = service.bootstrap()

    /**
     * Phase 1 receive entry point. Android sees a `media.blob.advertise`
     * on either the chat or the media-control stream, calls in here,
     * fetch happens, ack goes back via `ackSender`.
     */
    suspend fun handleAdvertise(frame: HermesRealtimeRelayFrame, ackSender: AdvertiseSender) {
        if (!settingsProvider()) return
        val media = frame.media ?: return
        val manifest = media.attachment ?: return
        val ticket = media.blobTicket ?: return

        bumpInFlight(+1)
        var status: HermesRealtimeRelayMediaAck.Status = HermesRealtimeRelayMediaAck.Status.RECEIVED
        var reason: String? = null
        try {
            val (destination, _) = service.fetch(ticketText = ticket, manifest = manifest)
            _lastReceivedAttachment.value =
                ReceivedAttachment(
                    id = manifest.manifestId,
                    manifest = manifest,
                    destinationFile = destination,
                )
            analytics?.transferCompleted(
                sizeBytes = manifest.size,
                durationSeconds = 0.0,
                didResume = false,
            )
        } catch (err: MediaFileTransferService.ServiceError) {
            status = HermesRealtimeRelayMediaAck.Status.REJECTED
            reason = err.message
            _lastError.value = Failure.FetchFailed(reason ?: "")
            analytics?.transferFailed(sizeBytes = manifest.size, failureCode = err.javaClass.simpleName)
        } catch (err: IOException) {
            status = HermesRealtimeRelayMediaAck.Status.REJECTED
            reason = err.message
            _lastError.value = Failure.FetchFailed(reason ?: "")
            analytics?.transferFailed(sizeBytes = manifest.size, failureCode = err.javaClass.simpleName)
        } finally {
            bumpInFlight(-1)
        }

        val ack =
            HermesRealtimeRelayMediaAck(
                manifestId = manifest.manifestId,
                status = status,
                reason = reason,
            )
        val ackFrame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK,
                uid = frame.uid,
                connectionId = frame.connectionId,
                requestId = manifest.manifestId,
                media =
                HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.BLOB_ADVERTISE.raw,
                    ack = ack,
                ),
            )
        runCatching { ackSender.send(ackFrame) }
    }

    /**
     * Publish a file from Android and emit a `media.blob.advertise`
     * frame to Mac. Resolution order:
     *   1. Explicit `advertiseSender` override (tests).
     *   2. The persistent media-control coordinator (production).
     *   3. `Failure.DispatchUnavailable` — never silently drops a
     *      user-initiated send.
     */
    suspend fun sendFile(
        uri: Uri,
        uid: String,
        connectionID: String,
        peerDeviceID: String?,
        advertiseSender: AdvertiseSender? = null,
    ): HermesRealtimeRelayAttachmentManifest {
        if (!settingsProvider()) throw Failure.SettingDisabled
        val cached =
            materializeUriToCache(uri)
                ?: throw Failure.FileMissing(uri.toString())

        bumpInFlight(+1)
        try {
            val publish = publishCachedFile(cached, peerDeviceID)
            emitAdvertiseFrame(
                publish = publish,
                uid = uid,
                connectionID = connectionID,
                advertiseSender = advertiseSender,
            )
            _lastSentManifestID.value = publish.manifest.manifestId
            return publish.manifest
        } finally {
            bumpInFlight(-1)
        }
    }

    private suspend fun publishCachedFile(cached: File, peerDeviceID: String?): MediaFileTransferService.PublishResult {
        return try {
            service.publish(localFile = cached, peerDeviceID = peerDeviceID)
        } catch (err: MediaFileTransferService.ServiceError) {
            val failure = Failure.PublishFailed(err.message ?: err.javaClass.simpleName)
            _lastError.value = failure
            throw failure
        }
    }

    private suspend fun emitAdvertiseFrame(
        publish: MediaFileTransferService.PublishResult,
        uid: String,
        connectionID: String,
        advertiseSender: AdvertiseSender?,
    ) {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE,
                uid = uid,
                connectionId = connectionID,
                requestId = publish.manifest.manifestId,
                media =
                HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.BLOB_ADVERTISE.raw,
                    attachment = publish.manifest,
                    blobTicket = publish.ticketText,
                ),
            )

        try {
            if (advertiseSender != null) {
                advertiseSender.send(frame)
            } else {
                requireControlCoordinator().send(frame)
            }
        } catch (err: Failure) {
            throw err
        } catch (err: IOException) {
            throw mapAdvertiseEmitError(err)
        }
    }

    private fun mapAdvertiseEmitError(err: IOException): Throwable {
        val failure = Failure.PublishFailed("advertise emit: ${err.message ?: err.javaClass.simpleName}")
        _lastError.value = failure
        return failure
    }

    private suspend fun requireControlCoordinator(): MediaControlStreamCoordinator = mutex.withLock { controlCoordinator }
        ?: run {
            _lastError.value = Failure.DispatchUnavailable
            throw Failure.DispatchUnavailable
        }

    private fun bumpInFlight(delta: Int) {
        _inFlightCount.value = (_inFlightCount.value + delta).coerceAtLeast(0)
    }

    private suspend fun materializeUriToCache(uri: Uri): File? = withContext(Dispatchers.IO) {
        val resolver: ContentResolver = appContext.contentResolver
        val displayName = queryDisplayName(resolver, uri) ?: "attachment_${System.currentTimeMillis()}"
        val cacheRoot = File(appContext.cacheDir, "mercury_outbox").also { it.mkdirs() }
        val target = AndroidFileTransferCachePath.targetFile(
            cacheRoot,
            displayName,
            uniqueSuffix = UUID.randomUUID().toString(),
        )
        try {
            resolver.openInputStream(uri).use { input ->
                if (input == null) return@withContext null
                FileOutputStream(target).use { out -> input.copyTo(out) }
            }
            target
        } catch (_: Throwable) {
            null
        }
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        }.getOrNull()
    }
}

internal object AndroidFileTransferCachePath {
    private const val MAX_CACHE_NAME_LENGTH = 96
    private val parentDirectoryMarker = Regex("\\.{2,}")

    fun targetFile(cacheRoot: File, displayName: String, uniqueSuffix: String? = null): File {
        val root = cacheRoot.canonicalFile
        val target = File(root, safeDisplayName(displayName, uniqueSuffix)).canonicalFile
        require(target.parentFile?.canonicalFile == root) {
            "attachment cache target must remain inside the outbox directory"
        }
        return target
    }

    fun safeDisplayName(displayName: String, uniqueSuffix: String? = null): String {
        val leafName =
            displayName
                .trim()
                .replace('\\', '/')
                .substringAfterLast('/')
        val sanitized = leafName
            .map { character -> if (isPortableFilenameCharacter(character)) character else '_' }
            .joinToString(separator = "")
            .replace(parentDirectoryMarker, "_")
            .trim('.', '_', '-')
            .ifBlank { "attachment" }
        val safeSuffix = uniqueSuffix
            ?.map { character -> if (isPortableFilenameCharacter(character)) character else '_' }
            ?.joinToString(separator = "")
            ?.replace(parentDirectoryMarker, "_")
            ?.trim('.', '_', '-')
            ?.take(32)
            ?.takeIf { it.isNotBlank() }
            ?.let { "-$it" }
            .orEmpty()
        val extensionStart = sanitized.lastIndexOf('.')
        val extension = if (
            extensionStart > 0 &&
            extensionStart < sanitized.lastIndex &&
            sanitized.length - extensionStart <= 16
        ) {
            sanitized.substring(extensionStart)
        } else {
            ""
        }
        val stem = if (extension.isEmpty()) sanitized else sanitized.substring(0, extensionStart).ifBlank { "attachment" }
        val maxStemLength = (MAX_CACHE_NAME_LENGTH - extension.length - safeSuffix.length).coerceAtLeast(1)
        return stem.take(maxStemLength) + safeSuffix + extension
    }

    private fun isPortableFilenameCharacter(character: Char): Boolean {
        return character.isLetterOrDigit() || character == '.' || character == '_' || character == '-'
    }
}
