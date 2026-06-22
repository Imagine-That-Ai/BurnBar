package com.openburnbar.data.media

import com.openburnbar.irohrelay.BlobTransferStats
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.irohrelay.IrohBlobBackend
import com.openburnbar.irohrelay.IrohBlobTransferLimits
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class MediaFileTransferServiceTest {
    private lateinit var tempRoot: File
    private lateinit var storeDirectory: File
    private lateinit var inboxDirectory: File

    @Before
    fun setUp() {
        tempRoot = createTempDirectory("mercury-file-transfer").toFile()
        storeDirectory = File(tempRoot, "store")
        inboxDirectory = File(tempRoot, "inbox")
    }

    @After
    fun tearDown() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun fetch_writesPeerControlledManifestToDirectInboxChild() = runTest {
        val backend = RecordingBlobBackend()
        val service = service(backend)

        val (destination, stats) =
            service.fetch(
                ticketText = "ticket-text",
                manifest =
                manifest(
                    blobHash = "../tickets/../../remote\\blob",
                    filename = "photos/avatar.png/../../escape.jpg",
                ),
            )

        val fetchedDestination = File(requireNotNull(backend.fetchedDestination))
        assertEquals(destination.canonicalFile, fetchedDestination.canonicalFile)
        assertEquals(inboxDirectory.canonicalFile, fetchedDestination.parentFile?.canonicalFile)
        assertFalse(fetchedDestination.name.contains('/'))
        assertFalse(fetchedDestination.name.contains('\\'))
        assertFalse(fetchedDestination.name.contains(".."))
        assertTrue(fetchedDestination.name.endsWith(".jpg"))
        assertEquals(1, backend.fetchCalls)
        assertEquals(42L, backend.fetchedExpectedSizeBytes)
        assertEquals("hash", stats.blake3Hash)
    }

    @Test
    fun fetch_rejectsBlankBlobHashBeforeBackendWrite() = runTest {
        val backend = RecordingBlobBackend()
        val service = service(backend)

        val error =
            runCatching {
                service.fetch(
                    ticketText = "ticket-text",
                    manifest = manifest(blobHash = "   ", filename = "photo.png"),
                )
            }.exceptionOrNull()

        assertTrue(error is MediaFileTransferService.ServiceError.InvalidManifest)
        assertEquals(0, backend.fetchCalls)
    }

    @Test
    fun fetch_rejectsControlCharactersBeforeBackendWrite() = runTest {
        val backend = RecordingBlobBackend()
        val service = service(backend)

        val error =
            runCatching {
                service.fetch(
                    ticketText = "ticket-text",
                    manifest = manifest(blobHash = "blob-hash", filename = "photo\u0000.png"),
                )
            }.exceptionOrNull()

        assertTrue(error is MediaFileTransferService.ServiceError.InvalidManifest)
        assertEquals(0, backend.fetchCalls)
    }

    @Test
    fun fetch_rejectsNegativeManifestSizeBeforeBackendWrite() = runTest {
        val backend = RecordingBlobBackend()
        val service = service(backend)

        val error =
            runCatching {
                service.fetch(
                    ticketText = "ticket-text",
                    manifest = manifest(blobHash = "blob-hash", filename = "photo.png", size = -1),
                )
            }.exceptionOrNull()

        assertTrue(error is MediaFileTransferService.ServiceError.InvalidManifest)
        assertEquals(0, backend.fetchCalls)
    }

    @Test
    fun fetch_rejectsOversizedManifestBeforeBackendWrite() = runTest {
        val backend = RecordingBlobBackend()
        val service = service(backend)

        val error =
            runCatching {
                service.fetch(
                    ticketText = "ticket-text",
                    manifest =
                    manifest(
                        blobHash = "blob-hash",
                        filename = "photo.png",
                        size = IrohBlobTransferLimits.MAX_EXPECTED_FETCH_BYTES + 1,
                    ),
                )
            }.exceptionOrNull()

        assertTrue(error is MediaFileTransferService.ServiceError.InvalidManifest)
        assertEquals(0, backend.fetchCalls)
    }

    private fun service(backend: RecordingBlobBackend): MediaFileTransferService = MediaFileTransferService(
        backend = backend,
        configuration =
        MediaFileTransferService.Configuration(
            storeDirectory = storeDirectory,
            inboxDirectory = inboxDirectory,
            secretKeyProvider = { IrohSecretKeyMaterial(ByteArray(32) { 7 }) },
            relayURL = "https://relay.example.com",
        ),
    )

    private fun manifest(blobHash: String, filename: String, size: Long = 42): HermesRealtimeRelayAttachmentManifest {
        return HermesRealtimeRelayAttachmentManifest(
            manifestId = "att_test",
            blobHash = blobHash,
            filename = filename,
            mime = "image/jpeg",
            size = size,
            peerDeviceId = "peer-device-1",
            createdAt = 0.0,
        )
    }

    private class RecordingBlobBackend : IrohBlobBackend {
        var fetchCalls = 0
            private set
        var fetchedDestination: String? = null
            private set
        var fetchedExpectedSizeBytes: Long? = null
            private set

        override suspend fun bootstrap(secret: ByteArray, storeDirectoryPath: String, relayURL: String?): IrohEndpointIdentity {
            return IrohEndpointIdentity(
                nodeId = "node-id",
                rawPublicKey = ByteArray(32) { 3 },
                relayURL = relayURL,
            )
        }

        override suspend fun publishBlob(localPath: String): String = "ticket-text"

        override suspend fun fetchBlob(ticketText: String, destination: String, expectedSizeBytes: Long?): BlobTransferStats {
            fetchCalls += 1
            fetchedDestination = destination
            fetchedExpectedSizeBytes = expectedSizeBytes
            return BlobTransferStats(
                bytesTotal = 42,
                blake3Hash = "hash",
                durationMillis = 5,
                didResume = false,
            )
        }

        override suspend fun identity(): IrohEndpointIdentity = IrohEndpointIdentity(
            nodeId = "node-id",
            rawPublicKey = ByteArray(32) { 3 },
        )

        override suspend fun shutdown() = Unit
    }
}
