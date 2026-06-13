package com.openburnbar.data.computeruse

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class RemoteUnlockSavedCredentialStoreTest {
    private val backing = ConcurrentHashMap<String, String?>()
    private lateinit var context: Context

    @Before
    fun setUp() {
        backing.clear()
        mockAndroidBase64()

        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        every { editor.putString(any(), any()) } answers {
            backing[firstArg()] = secondArg()
            editor
        }
        every { editor.remove(any()) } answers {
            backing.remove(firstArg<String>())
            editor
        }
        every { editor.apply() } answers {}
        every { editor.commit() } returns true

        val prefs = mockk<SharedPreferences>()
        every { prefs.contains(any()) } answers { backing.containsKey(firstArg()) }
        every { prefs.getString(any(), any()) } answers {
            backing.getOrDefault(firstArg<String>(), secondArg<String?>())
        }
        every { prefs.edit() } returns editor

        context = mockk(relaxed = true)
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns prefs
    }

    @After
    fun tearDown() {
        unmockkStatic(android.util.Base64::class)
    }

    @Test
    fun hasCredentialRequiresWrappedPayloadAndIvForSameStoreKey() {
        val store = RemoteUnlockSavedCredentialStore(context)
        backing[ciphertextPreferenceKey("mac-1")] = "wrapped"

        assertFalse(store.hasCredential("mac-1"))

        backing[ivPreferenceKey("mac-1")] = "iv"

        assertTrue(store.hasCredential("mac-1"))
        assertFalse(store.hasCredential("mac-2"))
    }

    @Test
    fun deleteRemovesBothStoredCredentialFields() {
        val store = RemoteUnlockSavedCredentialStore(context)
        backing[ciphertextPreferenceKey("mac-1")] = "wrapped"
        backing[ivPreferenceKey("mac-1")] = "iv"

        store.delete("mac-1")

        assertFalse(backing.containsKey(ciphertextPreferenceKey("mac-1")))
        assertFalse(backing.containsKey(ivPreferenceKey("mac-1")))
    }

    @Test
    fun loadReturnsNullForMalformedStoredCredential() {
        val store = RemoteUnlockSavedCredentialStore(context)
        backing[ciphertextPreferenceKey("mac-1")] = "not-base64"
        backing[ivPreferenceKey("mac-1")] = "still-not-base64"

        assertNull(store.load("mac-1"))
    }

    private fun mockAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(firstArg())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }
    }

    private fun ciphertextPreferenceKey(storeKey: String): String = "credential.${scopedKey(storeKey)}"

    private fun ivPreferenceKey(storeKey: String): String = "iv.${scopedKey(storeKey)}"

    private fun scopedKey(storeKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(storeKey.toByteArray(Charsets.UTF_8))
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }
}
