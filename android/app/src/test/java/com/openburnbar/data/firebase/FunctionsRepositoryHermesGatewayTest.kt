package com.openburnbar.data.firebase

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FunctionsRepositoryHermesGatewayTest {
    @Test
    fun hermesGatewayDeviceGrantPayloadAdvertisesProductionHpkeV3Capabilities() {
        val payload =
            buildHermesGatewayDeviceGrantPayload(
                userCode = "ABCD1234",
                displayName = "Android proof device",
                phoneRelayPublicKey = "phone-p256-x963",
                phoneRelayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
                phoneRelayEncryption = HermesRelayCrypto.ALGORITHM_V3,
                clientAppBuild = "1.0-test",
            )

        assertEquals("ABCD1234", payload["userCode"])
        assertEquals("burnbar:home", payload["destinationId"])
        assertEquals("Android proof device", payload["displayName"])
        assertEquals("phone-p256-x963", payload["phoneRelayPublicKey"])
        assertEquals(
            listOf(HermesRelayCrypto.GATEWAY_KEY_VERSION, HermesRelayCrypto.KEY_VERSION_V3),
            payload["supportsRelayEnvelopeVersions"],
        )
        assertEquals(HermesRelayCrypto.KEY_VERSION_V3, payload["preferredRelayEnvelopeVersion"])
        assertEquals(true, payload["supportsHpkeV3"])
        assertEquals("android", payload["clientPlatform"])
        assertEquals("1.0-test", payload["clientAppBuild"])
        assertEquals(HermesRelayCrypto.KEY_VERSION_V3, payload["phoneRelayKeyVersion"])
        assertEquals(HermesRelayCrypto.ALGORITHM_V3, payload["phoneRelayEncryption"])
    }

    @Test
    fun hermesGatewayDeviceGrantPayloadDoesNotAdvertiseV3WithoutAPhoneRelayKey() {
        val payload =
            buildHermesGatewayDeviceGrantPayload(
                userCode = "ABCD1234",
                phoneRelayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
                phoneRelayEncryption = HermesRelayCrypto.ALGORITHM_V3,
            )

        assertFalse(payload.containsKey("supportsRelayEnvelopeVersions"))
        assertFalse(payload.containsKey("preferredRelayEnvelopeVersion"))
        assertFalse(payload.containsKey("supportsHpkeV3"))
        assertFalse(payload.containsKey("clientPlatform"))
        assertTrue(payload.containsKey("phoneRelayKeyVersion"))
        assertTrue(payload.containsKey("phoneRelayEncryption"))
    }
}
