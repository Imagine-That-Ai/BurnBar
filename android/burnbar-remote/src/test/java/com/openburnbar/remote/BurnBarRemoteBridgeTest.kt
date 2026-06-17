package com.openburnbar.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnBarRemoteBridgeTest {
    @Test
    fun readinessReportsStableProtocolSurface() {
        val readiness = BurnBarRemoteBridge.readiness()

        assertEquals("burnbar-remote/v1", readiness.protocolVersion)
        assertTrue(readiness.supportsIrohTransport)
        assertTrue(readiness.supportsAdaptiveQuality)
        assertTrue(readiness.supportsPermissionGate)
        assertEquals(BurnBarRemoteBridge.isNativeAvailable(), readiness.nativeBridgeAvailable)
    }

    @Test
    fun scaledDimensionsMatchRustContract() {
        val scaled = BurnBarRemoteBridge.scaledDimensions(
            dimensions = BurnBarRemoteDimensions(width = 3840u, height = 2160u),
            numerator = 1u,
            denominator = 2u,
        )

        assertEquals(BurnBarRemoteDimensions(width = 1920u, height = 1080u), scaled)
    }

    @Test
    fun scaledDimensionsNeverReturnZero() {
        val scaled = BurnBarRemoteBridge.scaledDimensions(
            dimensions = BurnBarRemoteDimensions(width = 1u, height = 1u),
            numerator = 0u,
            denominator = 10u,
        )

        assertEquals(BurnBarRemoteDimensions(width = 1u, height = 1u), scaled)
    }

    @Test
    fun permissionGateMatchesCoreModes() {
        assertTrue(
            BurnBarRemoteBridge.modeRequiresPermission(
                BurnBarRemoteSessionMode.Control,
                BurnBarRemotePermission.InjectInput,
            ),
        )
        assertFalse(
            BurnBarRemoteBridge.modeRequiresPermission(
                BurnBarRemoteSessionMode.ViewOnly,
                BurnBarRemotePermission.InjectInput,
            ),
        )
    }
}
