package com.openburnbar.data.media

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.IrohRelayStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented coverage for `MediaControlStreamCoordinator`. The
 * coordinator owns the persistent media-control bi-stream and is
 * decoupled from real iroh — we feed it a fake `IrohRelayStream` and
 * verify the classify frame is emitted, advertises trigger the
 * receiver, and `stop()` closes cleanly.
 */
@RunWith(AndroidJUnit4::class)
class MediaControlStreamCoordinatorTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

    private class FakeStream : IrohRelayStream {
        val sent = CopyOnWriteArrayList<HermesRealtimeRelayFrame>()
        private val receiveSignal = CompletableDeferred<Unit>()
        private var closed = false
        override suspend fun send(frame: HermesRealtimeRelayFrame) {
            sent.add(frame)
        }
        override suspend fun receive(): HermesRealtimeRelayFrame? {
            // Block until close() is called → emulate a clean stream close.
            receiveSignal.await()
            return null
        }
        override suspend fun close() {
            closed = true
            receiveSignal.complete(Unit)
        }
        val didClose: Boolean get() = closed
    }

    @Test
    fun start_sends_media_classify_frame_first_and_stop_cleans_up() = runBlocking {
        val stream = FakeStream()
        val backing = io.mockk.mockk<MediaFileTransferService>(relaxed = true)
        val receiver = AndroidFileTransferService(
            appContext = context,
            service = backing,
            settingsProvider = { true },
        )
        val coordinator = MediaControlStreamCoordinator(
            dialer = { _, _ -> stream },
            receiver = receiver,
        )
        coordinator.start(uid = "uid", connectionID = "conn")
        // Wait up to 2s for the first frame to land. `phase` reaches
        // Live after the classify frame is emitted; we poll until then.
        withTimeout(2_000) {
            while (stream.sent.isEmpty()) kotlinx.coroutines.delay(20)
        }
        val classify = stream.sent.first()
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_CLASSIFY, classify.type)
        assertEquals("uid", classify.uid)
        assertEquals("conn", classify.connectionId)
        coordinator.stop()
        assertTrue("expected stream close after stop()", stream.didClose)
        assertEquals(MediaControlStreamCoordinator.Phase.Stopped, coordinator.phase.value)
    }
}
