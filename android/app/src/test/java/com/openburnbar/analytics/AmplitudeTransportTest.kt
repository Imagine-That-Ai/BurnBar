package com.openburnbar.analytics

import android.content.Context
import com.amplitude.android.Amplitude
import com.amplitude.android.Configuration
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AmplitudeTransportTest {
    @Test
    fun `analytics opt in cannot enable SDK diagnostics and revoke opts out`() {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        val configuration = slot<Configuration>()
        val sdk = mockk<Amplitude>()
        val create = mockk<(Configuration) -> Amplitude>()
        every { create(capture(configuration)) } returns sdk
        every { sdk.configuration } answers { configuration.captured }
        val transport = AmplitudeTransport(context, "test-key", "anonymous-id", createAmplitude = create)

        transport.start()
        transport.start()

        verify(exactly = 1) { create(any()) }
        assertTrue(transport.isStarted)
        assertFalse(configuration.captured.enableDiagnostics)
        assertTrue(configuration.captured.autocapture.isEmpty())
        assertFalse(configuration.captured.useAdvertisingIdForDeviceId)
        assertFalse(configuration.captured.useAppSetIdForDeviceId)
        assertFalse(configuration.captured.optOut)

        transport.stop()

        assertTrue(configuration.captured.optOut)
        assertFalse(transport.isStarted)
    }

    @Test
    fun `missing key never constructs the SDK`() {
        val context = mockk<Context>()
        val create = mockk<(Configuration) -> Amplitude>()
        for (key in listOf(null, "")) {
            val transport = AmplitudeTransport(context, key, "anonymous-id", createAmplitude = create)
            transport.start()
            assertFalse(transport.isStarted)
        }
        verify(exactly = 0) { create(any()) }
    }
}
