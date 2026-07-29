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

        assertEquals("android-device-id", DevicesStore.currentAndroidDeviceID(context))
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
                currentDeviceIDs = setOf("phone-id"),
            )

        assertEquals("phone-id", record.id)
        assertEquals("Galaxy S24", record.displayName)
        assertEquals("Android", record.platform)
        assertEquals("android-escrow-hash", record.escrowDeviceId)
        assertEquals(Date(2_000L), record.lastSeen)
        assertEquals(true, record.isCurrentDevice)
    }

    @Test
    fun `merge and dedupe keep the trusted freshest physical device`() {
        val stale =
            DeviceRecord(
                id = "old-install",
                displayName = "Alberto's Phone",
                platform = "iOS",
                lastSeen = Date(1_000L),
            )
        val fresh =
            DeviceRecord(
                id = "current-install",
                displayName = "Alberto's Phone",
                platform = "ios",
                lastSeen = Date(2_000L),
            )
        val trust =
            DeviceRecord(
                id = "current-install",
                displayName = "Unknown",
                platform = "iOS",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_500L),
            )

        val merged = DevicesStore.mergeDeviceRecords(listOf(stale, fresh), listOf(trust))
        val visible = DevicesStore.deduplicated(merged)

        assertEquals(1, visible.size)
        assertEquals("current-install", visible.single().id)
        assertEquals(DeviceTrustState.TRUSTED, visible.single().trustState)
        assertEquals(Date(2_000L), visible.single().lastSeen)
    }

    @Test
    fun `merge joins presence and escrow records via escrowDeviceId cross-reference`() {
        val presence =
            DeviceRecord(
                id = "sha256-of-android-id",
                displayName = "Unknown",
                platform = "android",
                lastSeen = Date(2_000L),
                escrowDeviceId = "android-escrow-hash",
            )
        val escrow =
            DeviceRecord(
                id = "android-escrow-hash",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
                escrowDeviceId = "android-escrow-hash",
            )

        val merged = DevicesStore.mergeDeviceRecords(listOf(presence), listOf(escrow))

        assertEquals(1, merged.size)
        assertEquals("sha256-of-android-id", merged.single().id)
        assertEquals("Samsung SM-S928B", merged.single().displayName)
        assertEquals(DeviceTrustState.TRUSTED, merged.single().trustState)
        assertEquals("android-escrow-hash", merged.single().escrowDeviceId)
        assertEquals(Date(2_000L), merged.single().lastSeen)
    }

    @Test
    fun `merge coalesces current-device presence and escrow identities into one record`() {
        val presence =
            DeviceRecord(
                id = "sha256-of-android-id",
                displayName = "Unknown",
                platform = "android",
                lastSeen = Date(2_000L),
                isCurrentDevice = true,
            )
        val escrow =
            DeviceRecord(
                id = "android-escrow-hash",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
                isCurrentDevice = true,
                escrowDeviceId = "android-escrow-hash",
            )

        val merged = DevicesStore.mergeDeviceRecords(listOf(presence), listOf(escrow))

        assertEquals(1, merged.size)
        assertEquals("Samsung SM-S928B", merged.single().displayName)
        assertEquals(DeviceTrustState.TRUSTED, merged.single().trustState)
        assertEquals("android-escrow-hash", merged.single().escrowDeviceId)
        assertEquals(true, merged.single().isCurrentDevice)
    }

    @Test
    fun `dedupe prefers the active reinstall over a stale trusted record`() {
        val staleTrusted =
            DeviceRecord(
                id = "android-old-install",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
            )
        val freshReinstall =
            DeviceRecord(
                id = "android-new-install",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.PENDING,
                lastSeen = Date(2_000L),
            )

        val visible = DevicesStore.deduplicated(listOf(staleTrusted, freshReinstall))

        assertEquals(1, visible.size)
        assertEquals("android-new-install", visible.single().id)
    }

    @Test
    fun `dedupe never lets a revoked record mask an active one`() {
        val revokedFresh =
            DeviceRecord(
                id = "android-revoked",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.REVOKED,
                lastSeen = Date(3_000L),
            )
        val trustedOlder =
            DeviceRecord(
                id = "android-trusted",
                displayName = "Samsung SM-S928B",
                platform = "Android",
                trustState = DeviceTrustState.TRUSTED,
                lastSeen = Date(1_000L),
            )

        val visible = DevicesStore.deduplicated(listOf(revokedFresh, trustedOlder))

        assertEquals(1, visible.size)
        assertEquals("android-trusted", visible.single().id)
    }

    @Test
    fun `connected device subtitle reports trust states instead of raw documents`() {
        val devices =
            listOf(
                DeviceRecord(id = "current", isCurrentDevice = true),
                DeviceRecord(id = "pending"),
                DeviceRecord(id = "revoked", trustState = DeviceTrustState.REVOKED),
            )

        assertEquals(
            "1 trusted · 1 pending · 1 revoked",
            connectedDevicesSubtitle(devices),
        )
    }

    @Test
    fun `connected device subtitle counts a revoked current device as revoked only`() {
        val devices =
            listOf(
                DeviceRecord(id = "current", isCurrentDevice = true, trustState = DeviceTrustState.REVOKED),
            )

        assertEquals(
            "0 trusted · 0 pending · 1 revoked",
            connectedDevicesSubtitle(devices),
        )
    }
}
