package com.openburnbar.data.media

import com.openburnbar.irohrelay.BlobTransferStats
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.irohrelay.IrohBlobBackend
import com.openburnbar.irohrelay.IrohBlobBackendError
import com.openburnbar.irohrelay.IrohBlobTransferLimits
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

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
    private companion object {
        const val MILLIS_PER_SECOND = 1000.0
        const val APPLE_REFERENCE_EPOCH_OFFSET_SECONDS = 978_307_200.0
        const val SAFE_NAME_PREFIX_LENGTH = 48
        const val MAX_EXTENSION_LENGTH = 16
        const val MIN_VISIBLE_CHARACTER_CODE = 0x20
        const val DELETE_CHARACTER_CODE = 0x7f
        const val BYTE_MASK = 0xff
        const val HEX_RADIX = 16
        val PARENT_DIRECTORY_MARKER = Regex("\\.{2,}")
    }

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

        data class InvalidManifest(val detail: String) : ServiceError("Invalid attachment manifest: $detail")
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
            val deferred =
                scope.async {
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

        val ticketText: String =
            try {
                backend.publishBlob(localFile.absolutePath)
            } catch (err: IrohBlobBackendError) {
                throw ServiceError.PublishFailed(err.message ?: err.javaClass.simpleName)
                    .also { it.initCause(err) }
            }

        val mime = inferMime(localFile)
        val blobHash = ContentBlake3.hashFile(localFile)
        val manifest =
            HermesRealtimeRelayAttachmentManifest(
                manifestId = "att_" + UUID.randomUUID().toString().lowercase(),
                blobHash = blobHash,
                filename = localFile.name,
                mime = mime,
                size = localFile.length(),
                peerDeviceId = peerDeviceID,
                createdAt = swiftReferenceSeconds(System.currentTimeMillis()),
            )
        return PublishResult(manifest = manifest, ticketText = ticketText)
    }

    /** Fetch a peer's blob into the inbox directory and return the destination URL + transfer stats. */
    suspend fun fetch(ticketText: String, manifest: HermesRealtimeRelayAttachmentManifest): Pair<File, BlobTransferStats> {
        val expectedSizeBytes =
            try {
                IrohBlobTransferLimits.validateExpectedFetchSize(manifest.size)
                manifest.size
            } catch (err: IrohBlobBackendError) {
                throw ServiceError.InvalidManifest(err.message ?: err.javaClass.simpleName)
                    .also { it.initCause(err) }
            }
        bootstrap()
        val destination = inboxFile(manifest)
        val stats =
            try {
                backend.fetchBlob(
                    ticketText = ticketText,
                    destination = destination.absolutePath,
                    expectedSizeBytes = expectedSizeBytes,
                )
            } catch (err: IrohBlobBackendError) {
                throw ServiceError.FetchFailed(err.message ?: err.javaClass.simpleName)
                    .also { it.initCause(err) }
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
        val inboxRoot = configuration.inboxDirectory.canonicalFile
        val ext = safeExtension(manifest.filename)
        val nameBase = safeInboxNameBase(manifest.blobHash)
        val fullName = if (ext.isNotBlank()) "$nameBase.$ext" else nameBase
        val destination = File(inboxRoot, fullName).canonicalFile
        if (destination.parentFile?.canonicalFile != inboxRoot) {
            throw ServiceError.InvalidManifest("attachment destination must remain inside the inbox directory")
        }
        return destination
    }

    private fun safeInboxNameBase(blobHash: String): String {
        val normalized = blobHash.trim()
        if (normalized.isBlank()) {
            throw ServiceError.InvalidManifest("blank blob hash")
        }
        if (containsControlCharacter(normalized)) {
            throw ServiceError.InvalidManifest("blob hash contains control characters")
        }

        val prefix =
            normalized
                .map { if (isPortableFilenameCharacter(it)) it else '_' }
                .joinToString(separator = "")
                .replace(PARENT_DIRECTORY_MARKER, "_")
                .trim('.', '_', '-')
                .take(SAFE_NAME_PREFIX_LENGTH)
                .ifBlank { "blob" }
        return "$prefix-${sha256Hex(normalized)}"
    }

    private fun safeExtension(filename: String): String {
        val normalized = filename.trim()
        if (normalized.isBlank()) {
            return ""
        }
        if (containsControlCharacter(normalized)) {
            throw ServiceError.InvalidManifest("filename contains control characters")
        }

        val leafName =
            normalized
                .replace('\\', '/')
                .substringAfterLast('/')
        val ext = leafName.substringAfterLast('.', missingDelimiterValue = "").lowercase()
        if (ext.isBlank()) {
            return ""
        }
        if (ext.length > MAX_EXTENSION_LENGTH || ext.any { !it.isLetterOrDigit() }) {
            return ""
        }
        return ext
    }

    private fun isPortableFilenameCharacter(character: Char): Boolean {
        return character.isLetterOrDigit() || character == '.' || character == '_' || character == '-'
    }

    private fun containsControlCharacter(value: String): Boolean {
        return value.any { it == '\u0000' || it.code < MIN_VISIBLE_CHARACTER_CODE || it.code == DELETE_CHARACTER_CODE }
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { byte ->
            (byte.toInt() and BYTE_MASK).toString(HEX_RADIX).padStart(2, '0')
        }
    }

    private fun ensureDirectoryExists(directory: File) {
        if (!directory.exists() && !directory.mkdirs() && !directory.exists()) {
            throw ServiceError.BackendUnavailable
        }
    }

    // Swift synthesizes AttachmentManifest.createdAt as a Codable Date, which JSONEncoder
    // emits/decodes as a NUMBER of seconds since the 2001-01-01 Apple reference epoch.
    // (Was an ISO string here, which the Mac's synthesized decoder rejected.)
    private fun swiftReferenceSeconds(epochMillis: Long): Double = epochMillis / MILLIS_PER_SECOND - APPLE_REFERENCE_EPOCH_OFFSET_SECONDS

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
