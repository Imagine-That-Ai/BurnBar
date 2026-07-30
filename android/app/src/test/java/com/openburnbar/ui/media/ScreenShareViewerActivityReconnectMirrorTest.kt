package com.openburnbar.ui.media

import android.util.Log
import androidx.compose.runtime.mutableStateOf
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.media.VideoReceivePipeline
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Reconnect tests for `ScreenShareViewerActivityControlSupport`:
 * [reconnectMirror] must mint a fresh mirror request through the Mercury
 * coordinator and track it as the active request — superseding the launch
 * intent's stale request ID and clearing per-session mirror state so
 * acknowledgements and stop frames for the retry are honored.
 */
class ScreenShareViewerActivityReconnectMirrorTest {
    private val status = mutableStateOf<String?>(null)
    private val coordinator = mockk<MediaControlStreamCoordinator>(relaxed = true)
    private val activity = mockk<ScreenShareViewerActivity>(relaxed = true)

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.i(any(), any()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0

        mockkStatic(FirebaseAuth::class)
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns null
        every { FirebaseAuth.getInstance() } returns auth

        BurnBarApplication.mediaControlCoordinator = coordinator
        coEvery { coordinator.requestMirror(any(), any(), any()) } returns "mirror-reconnect-1"

        every { activity.controlScope } returns CoroutineScope(Dispatchers.Unconfined)
        every { activity.controlStatus } returns status
        every { activity.pipeline } returns VideoReceivePipeline()
    }

    @After
    fun tearDown() {
        BurnBarApplication.mediaControlCoordinator = null
        unmockkStatic(FirebaseAuth::class)
        unmockkStatic(Log::class)
    }

    @Test
    fun `reconnect tracks the retried request as the active mirror request`() {
        activity.reconnectMirror()

        assertEquals("Mirror requested", status.value)
        verify { activity.reconnectedMirrorRequestID = "mirror-reconnect-1" }
        verify { activity.mirrorSessionID = null }
        verify { activity.mirrorViewerRole = null }
        verify { activity.mirrorStopSent = false }
    }
}
