package com.openburnbar.ui.smartdisplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SmartHubBridgeClientDiscoveryTest {
    @Test
    fun `merge discovered devices caps new overflow`() {
        val existing = (0 until SMART_DISPLAY_DISCOVERY_MAX_RESULTS).map { index ->
            device(id = "device-$index", name = "Clock $index")
        }

        val merged = mergeDiscoveredDevices(existing, device(id = "overflow", name = "Overflow"))

        assertEquals(SMART_DISPLAY_DISCOVERY_MAX_RESULTS, merged.size)
        assertFalse(merged.any { it.id == "overflow" })
    }

    @Test
    fun `merge discovered devices updates existing device at cap`() {
        val existing = (0 until SMART_DISPLAY_DISCOVERY_MAX_RESULTS).map { index ->
            device(id = "device-$index", name = "Clock $index", reachable = false)
        }

        val merged =
            mergeDiscoveredDevices(
                existing,
                device(id = "device-7", name = "Updated Clock", host = "10.0.0.7", port = 8080, reachable = true),
            )
        val updated = merged.single { it.id == "device-7" }

        assertEquals(SMART_DISPLAY_DISCOVERY_MAX_RESULTS, merged.size)
        assertEquals("Updated Clock", updated.name)
        assertEquals("10.0.0.7", updated.host)
        assertEquals(8080, updated.port)
        assertEquals(true, updated.reachable)
    }

    @Test
    fun `merge discovered devices sorts deterministically`() {
        val merged =
            mergeDiscoveredDevices(
                listOf(
                    device(id = "b", name = "Pixel"),
                    device(id = "a", name = "pixel"),
                    device(id = "z", name = "Awtrix"),
                ),
                device(id = "m", name = "Matrix"),
            )

        assertEquals(listOf("z", "m", "a", "b"), merged.map { it.id })
    }

    private fun device(id: String, name: String, host: String = "192.0.2.1", port: Int = 80, reachable: Boolean = true): PixelClockDevice {
        return PixelClockDevice(
            id = id,
            name = name,
            host = host,
            port = port,
            reachable = reachable,
        )
    }
}
