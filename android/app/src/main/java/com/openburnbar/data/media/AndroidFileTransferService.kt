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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.io.File
import java.io.FileOutputStream

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
            _lastReceivedAttachment.value = ReceivedAttachment(
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
        } catch (err: Throwable) {
            status = HermesRealtimeRelayMediaAck.Status.REJECTED
            reason = err.message
            _lastError.value = Failure.FetchFailed(reason ?: "")
            analytics?.transferFailed(sizeBytes = manifest.size, failureCode = err.javaClass.simpleName)
        } finally {
            bumpInFlight(-1)
        }

        val ack = HermesRealtimeRelayMediaAck(
            manifestId = manifest.manifestId,
            status = status,
            reason = reason,
        )
        val ackFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK,
            uid = frame.uid,
            connectionId = frame.connectionId,
            requestId = manifest.manifestId,
            media = HermesRealtimeRelayMediaPayload(
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
        val cached = materializeUriToCache(uri)
            ?: throw Failure.FileMissing(uri.toString())

        bumpInFlight(+1)
        try {
            val publish = try {
                service.publish(localFile = cached, peerDeviceID = peerDeviceID)
            } catch (err: MediaFileTransferService.ServiceError) {
                val failure = Failure.PublishFailed(err.message ?: err.javaClass.simpleName)
                _lastError.value = failure
                throw failure
            }

            val frame = HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE,
                uid = uid,
                connectionId = connectionID,
                requestId = publish.manifest.manifestId,
                media = HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.BLOB_ADVERTISE.raw,
                    attachment = publish.manifest,
                    blobTicket = publish.ticketText,
                ),
            )

            try {
                when {
                    advertiseSender != null -> advertiseSender.send(frame)
                    else -> {
                        val coordinator = mutex.withLock { controlCoordinator }
                            ?: run {
                                _lastError.value = Failure.DispatchUnavailable
                                throw Failure.DispatchUnavailable
                            }
                        coordinator.send(frame)
                    }
                }
            } catch (failure: Failure) {
                throw failure
            } catch (err: Throwable) {
                val failure = Failure.PublishFailed("advertise emit: ${err.message ?: err.javaClass.simpleName}")
                _lastError.value = failure
                throw failure
            }

            _lastSentManifestID.value = publish.manifest.manifestId
            return publish.manifest
        } finally {
            bumpInFlight(-1)
        }
    }

    private fun bumpInFlight(delta: Int) {
        _inFlightCount.value = (_inFlightCount.value + delta).coerceAtLeast(0)
    }

    private suspend fun materializeUriToCache(uri: Uri): File? = withContext(Dispatchers.IO) {
        val resolver: ContentResolver = appContext.contentResolver
        val displayName = queryDisplayName(resolver, uri) ?: "attachment_${System.currentTimeMillis()}"
        val cacheRoot = File(appContext.cacheDir, "mercury_outbox").also { it.mkdirs() }
        val target = File(cacheRoot, displayName)
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
                } else null
            }
        }.getOrNull()
    }
}
