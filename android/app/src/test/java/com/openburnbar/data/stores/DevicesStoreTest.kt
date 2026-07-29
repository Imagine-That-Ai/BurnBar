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
                    "lastSeenAtMillis" to 2_000L,
                    "updated_at_millis" to 1_000L,
                ),
                currentDeviceID = "phone-id",
            )

        assertEquals("phone-id", record.id)
        assertEquals("Galaxy S24", record.displayName)
        assertEquals("Android", record.platform)
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
}
