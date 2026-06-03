package com.openburnbar.data.stores

import android.content.ContentResolver
import android.content.Context
import android.provider.Settings
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
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
}
