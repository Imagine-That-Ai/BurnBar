package com.openburnbar.data.media

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openburnbar.irohrelay.BlobTransferStats
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented coverage for `AndroidFileTransferService`. Drives the
 * advertise → fetch → ack round-trip without standing up the iroh
 * runtime: `MediaFileTransferService` is mocked, and the device's
 * cache directory hosts the synthesised destination file.
 */
@RunWith(AndroidJUnit4::class)
class AndroidFileTransferServiceTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

    @Test
    fun advertise_emits_received_acknowledgment_on_success() = runBlocking {
        val cache = java.io.File(context.cacheDir, "mercury-instrtest-${System.nanoTime()}")
        cache.parentFile?.mkdirs()
        cache.writeText("payload")

        val backing = mockk<MediaFileTransferService>(relaxed = true)
        val stats = BlobTransferStats(
            bytesTotal = 7,
            blake3Hash = "abc",
            durationMillis = 1,
            didResume = false,
        )
        coEvery { backing.fetch(any(), any()) } returns (cache to stats)

        val service = AndroidFileTransferService(
            appContext = context,
            service = backing,
            settingsProvider = { true },
        )
        val manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId = "manifest-1",
            blobHash = "blob-hash",
            filename = "test.txt",
            mime = "text/plain",
            size = 7,
            createdAt = "2026-05-16T00:00:00Z",
        )
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE,
            uid = "uid",
            connectionId = "conn",
            requestId = "req",
            media = HermesRealtimeRelayMediaPayload(
                streamClass = MediaStreamClass.BLOB_ADVERTISE.raw,
                attachment = manifest,
                blobTicket = "ticket://abc",
            ),
        )
        val captured = slot<HermesRealtimeRelayFrame>()
        val sender = AndroidFileTransferService.AdvertiseSender { capturedFrame ->
            captured.captured = capturedFrame
        }
        service.handleAdvertise(frame = frame, ackSender = sender)
        assertTrue(captured.isCaptured)
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK, captured.captured.type)
        assertEquals(
            HermesRealtimeRelayMediaAck.Status.RECEIVED,
            captured.captured.media?.ack?.status,
        )
        coVerify { backing.fetch(any(), any()) }
    }

    @Test
    fun disabled_flag_throws_setting_disabled_on_send() {
        val backing = mockk<MediaFileTransferService>(relaxed = true)
        val service = AndroidFileTransferService(
            appContext = context,
            service = backing,
            settingsProvider = { false },
        )
        val ex = assertThrows(AndroidFileTransferService.Failure.SettingDisabled::class.java) {
            runBlocking {
                service.sendFile(
                    uri = Uri.parse("content://nowhere"),
                    uid = "uid",
                    connectionID = "conn",
                    peerDeviceID = null,
                )
            }
        }
        assertTrue(ex is AndroidFileTransferService.Failure.SettingDisabled)
    }
}
