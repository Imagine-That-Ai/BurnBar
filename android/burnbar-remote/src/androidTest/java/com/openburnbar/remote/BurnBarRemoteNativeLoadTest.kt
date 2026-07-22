package com.openburnbar.remote

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BurnBarRemoteNativeLoadTest {
    @Test
    fun committedAarLoadsAndExecutesProtocolSurface() {
        val readiness = BurnBarRemoteBridge.readiness()

        assertTrue(
            "loadFailure=${BurnBarRemoteNativeContext.lastLoadFailureForTesting()} " +
                "nativeCallFailure=${BurnBarRemoteBridge.lastNativeCallFailureForTesting()}",
            readiness.nativeBridgeAvailable,
        )
        assertEquals("burnbar-remote/v1", readiness.protocolVersion)
        assertEquals(
            BurnBarRemoteDimensions(width = 1920u, height = 1080u),
            BurnBarRemoteBridge.scaledDimensions(
                BurnBarRemoteDimensions(width = 3840u, height = 2160u),
                numerator = 1u,
                denominator = 2u,
            ),
        )
    }
}
