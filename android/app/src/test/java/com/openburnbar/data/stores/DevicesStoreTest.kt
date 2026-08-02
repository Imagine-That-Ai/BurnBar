package com.openburnbar.data.stores

import android.content.ContentResolver
import android.content.Context
import android.provider.Settings
import com.openburnbar.ui.you.connectedDevicesSubtitle
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Date
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class DevicesStoreTest {
    @Before
    fun setUp() {
        mockkStatic(Settings.Secure::class)
    }

    @After
    fun tearDown() {
        unmockkStatic(Settings.Secure::class)
    }

    @Test
    fun `currentAndroidDeviceID reads from supplied application context`() {
        val context = mockk<Context>()
        val resolver = mockk<ContentResolver>()
        every { context.contentResolver } returns resolver
        every { Settings.Secure.getString(resolver, Settings.Secure.ANDROID_ID) } returns "android-device-id"

        assertEquals(
            "077e8ba5b35e180f3b7d656b114d5fc54477ee8e7a1113fb2365f21d2dfef985",
            DevicesStore.currentAndroidDeviceID(context),
        )
    }

    @Test
    fun `currentAndroidDeviceID fails closed instead of crashing`() {
        val context = mockk<Context>()
        every { context.contentResolver } throws IllegalStateException("missing base context")

        assertNull(DevicesStore.currentAndroidDeviceID(context))
    }

    @Test
    fun `currentAndroidDeviceID accepts missing context`() {
        assertNull(DevicesStore.currentAndroidDeviceID(null))
    }

    @Test
    fun `general device decoder accepts production device fields`() {
        val record =
            DevicesStore.generalDeviceRecord(
                documentID = "fallback-id",
                data =
                mapOf(
                    "deviceId" to "phone-id",
                    "deviceName" to "Galaxy S24",
                    "platform" to "Android",
                    "escrowDeviceId" to "android-escrow-hash",
                    "lastSeenAtMillis" to 2_000L,
                    "updated_at_millis" to 1_000L,
                ),
                currentPresenceDeviceID = "phone-id",
            )

        assertEquals("phone-id", record.id)
        assertEquals("phone-id", record.presenceID)
        assertEquals("android-escrow-hash", record.escrowID)
        assertEquals("Galaxy S24", record.displayName)
        assertEquals("Android", record.platform)
        assertEquals(Date(2_000L), record.lastSeen)
        assertEquals(true, record.isCurrentDevice)
    }

    @Test
    fun `merge joins presence and escrow records through the published cross reference`() {
        val presence =
            DeviceRecord(
                id = "presence-sha256",
                presenceID = "presence-sha256",
                escrowID = "android-public-key-hash",
                displayName = "Unknown",
                platform = "android",
                lastSeen = Date(2_000L),
            )
        val escrow =
            DeviceRecord(
                id = "android-public-key-hash",
                escrowID = "android-public-key-hash",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
            )

        val merged = DevicesStore.mergeDeviceRecords(listOf(presence), listOf(escrow))

        assertEquals(1, merged.size)
        assertEquals("android-public-key-hash", merged.single().id)
        assertEquals("presence-sha256", merged.single().presenceID)
        assertEquals("android-public-key-hash", merged.single().escrowID)
        assertEquals("Samsung SM-S921U", merged.single().displayName)
        assertEquals(DeviceTrustState.TRUSTED, merged.single().trustState)
        assertEquals(Date(2_000L), merged.single().lastSeen)
    }

    @Test
    fun `merge reconciles current Android presence and escrow identities without a cross reference`() {
        val presence =
            DeviceRecord(
                id = "presence-sha256",
                presenceID = "presence-sha256",
                displayName = "Unknown",
                platform = "android",
                lastSeen = Date(2_000L),
                isCurrentDevice = true,
            )
        val escrow =
            DeviceRecord(
                id = "android-public-key-hash",
                escrowID = "android-public-key-hash",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
                isCurrentDevice = true,
            )

        val visible = DevicesStore.deduplicated(DevicesStore.mergeDeviceRecords(listOf(presence), listOf(escrow)))

        assertEquals(1, visible.size)
        assertEquals("android-public-key-hash", visible.single().id)
        assertEquals("presence-sha256", visible.single().presenceID)
        assertEquals("android-public-key-hash", visible.single().escrowID)
        assertEquals("Samsung SM-S921U", visible.single().displayName)
        assertEquals(DeviceTrustState.TRUSTED, visible.single().trustState)
        assertEquals(Date(2_000L), visible.single().lastSeen)
        assertEquals(true, visible.single().isCurrentDevice)
    }

    @Test
    fun `merge hides anonymous Android presence shadows when escrow devices exist`() {
        val stalePresence =
            DeviceRecord(
                id = "old-presence",
                presenceID = "old-presence",
                displayName = "Unknown",
                platform = "android",
                lastSeen = Date(1_000L),
            )
        val escrow =
            DeviceRecord(
                id = "android-public-key-hash",
                escrowID = "android-public-key-hash",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(2_000L),
            )

        val merged = DevicesStore.mergeDeviceRecords(listOf(stalePresence), listOf(escrow))

        assertEquals(listOf("android-public-key-hash"), merged.map { it.id })
    }

    @Test
    fun `same-name Android registrations remain distinct across reinstalls`() {
        val staleTrusted =
            DeviceRecord(
                id = "old-install",
                escrowID = "old-install",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
            )
        val freshPending =
            DeviceRecord(
                id = "new-install",
                escrowID = "new-install",
                displayName = "Samsung SM-S921U",
                platform = "android",
                trustState = DeviceTrustState.PENDING,
                lastSeen = Date(2_000L),
            )

        val visible = DevicesStore.deduplicated(listOf(staleTrusted, freshPending))

        assertEquals(listOf("new-install", "old-install"), visible.map { it.id })
        assertEquals(
            listOf(DeviceTrustState.PENDING, DeviceTrustState.TRUSTED),
            visible.map { it.trustState },
        )
    }

    @Test
    fun `same-name active and revoked registrations retain their stable identities`() {
        val revoked =
            DeviceRecord(
                id = "revoked-install",
                escrowID = "revoked-install",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.REVOKED,
                lastSeen = Date(2_000L),
            )
        val trusted =
            DeviceRecord(
                id = "trusted-install",
                escrowID = "trusted-install",
                displayName = "Samsung SM-S921U",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(2_000L),
            )

        val visible = DevicesStore.deduplicated(listOf(revoked, trusted))

        assertEquals(setOf("revoked-install", "trusted-install"), visible.map { it.id }.toSet())
        assertEquals(setOf("revoked-install", "trusted-install"), visible.map { it.stableIdentity }.toSet())
    }

    @Test
    fun `bulk revocation awaits each device rotation before starting the next`() = runTest {
        val devices =
            listOf(
                DeviceRecord(id = "first", escrowID = "escrow-first"),
                DeviceRecord(id = "second", escrowID = "escrow-second"),
                DeviceRecord(id = "third", escrowID = "escrow-third"),
            )
        val events = mutableListOf<String>()
        var activeRevocations = 0
        var maximumConcurrentRevocations = 0

        DevicesStore.revokeSequentially(devices) { device ->
            events += "start:${device.revocationDeviceID}"
            activeRevocations += 1
            maximumConcurrentRevocations = maxOf(maximumConcurrentRevocations, activeRevocations)
            delay(1)
            events += "finish:${device.revocationDeviceID}"
            activeRevocations -= 1
        }

        assertEquals(1, maximumConcurrentRevocations)
        assertEquals(
            listOf(
                "start:escrow-first",
                "finish:escrow-first",
                "start:escrow-second",
                "finish:escrow-second",
                "start:escrow-third",
                "finish:escrow-third",
            ),
            events,
        )
    }

    @Test
    fun `connected device subtitle reports exclusive trust states`() {
        val devices =
            listOf(
                DeviceRecord(id = "trusted", trustState = DeviceTrustState.TRUSTED),
                DeviceRecord(id = "pending"),
                DeviceRecord(
                    id = "revoked-current",
                    trustState = DeviceTrustState.REVOKED,
                    isCurrentDevice = true,
                ),
            )

        assertEquals(
            "1 trusted · 1 pending · 1 revoked",
            connectedDevicesSubtitle(devices),
        )
    }
}
