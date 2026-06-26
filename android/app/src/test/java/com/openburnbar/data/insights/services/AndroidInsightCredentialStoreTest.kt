package com.openburnbar.data.insights.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidInsightCredentialStoreTest {
    @Test
    fun `provider credentials persist only in secret storage`() {
        val secret = FakeInsightStringStorage()
        val endpoint = FakeInsightStringStorage()
        val legacy = FakeInsightStringStorage()
        val store = AndroidInsightCredentialStore(secret, endpoint, legacy)

        store.saveCredential("openai", "  fake-user-key  ")
        store.saveEndpoint("hermes", "  http://127.0.0.1:8642  ")

        assertEquals("fake-user-key", secret.values["credential.openai"])
        assertFalse(legacy.values.containsKey("credential.openai"))
        assertEquals("fake-user-key", store.credential("openai"))
        assertEquals("http://127.0.0.1:8642", endpoint.values["endpoint.hermes"])
        assertEquals("http://127.0.0.1:8642", store.endpoint("hermes"))
        assertFalse(secret.values.containsKey("endpoint.hermes"))
    }

    @Test
    fun `legacy plaintext credentials migrate to secret storage and are removed`() {
        val secret = FakeInsightStringStorage()
        val endpoint = FakeInsightStringStorage()
        val legacy =
            FakeInsightStringStorage(
                "credential.openai" to "  fake-legacy-key  ",
                "credential.anthropic" to "",
                "endpoint.hermes" to "http://127.0.0.1:8642",
            )

        val store = AndroidInsightCredentialStore(secret, endpoint, legacy)

        assertEquals("fake-legacy-key", secret.values["credential.openai"])
        assertFalse(legacy.values.containsKey("credential.openai"))
        assertFalse(legacy.values.containsKey("credential.anthropic"))
        assertEquals("fake-legacy-key", store.credential("openai"))
        assertEquals("http://127.0.0.1:8642", legacy.values["endpoint.hermes"])
    }

    @Test
    fun `encrypted credentials win over stale legacy credentials`() {
        val secret = FakeInsightStringStorage("credential.openai" to "fake-current-key")
        val endpoint = FakeInsightStringStorage()
        val legacy = FakeInsightStringStorage("credential.openai" to "fake-stale-key")

        val store = AndroidInsightCredentialStore(secret, endpoint, legacy)

        assertEquals("fake-current-key", store.credential("openai"))
        assertEquals("fake-current-key", secret.values["credential.openai"])
        assertFalse(legacy.values.containsKey("credential.openai"))
    }

    @Test
    fun `blank provider credential clears secret and legacy copies`() {
        val secret = FakeInsightStringStorage("credential.openai" to "fake-current-key")
        val endpoint = FakeInsightStringStorage()
        val legacy = FakeInsightStringStorage("credential.openai" to "fake-legacy-key")
        val store = AndroidInsightCredentialStore(secret, endpoint, legacy)

        store.saveCredential("openai", "   ")

        assertNull(store.credential("openai"))
        assertFalse(secret.values.containsKey("credential.openai"))
        assertFalse(legacy.values.containsKey("credential.openai"))
    }

    @Test
    fun `credential writes fail closed when secret storage cannot persist`() {
        val secret = FakeInsightStringStorage(failWrites = true)
        val endpoint = FakeInsightStringStorage()
        val store = AndroidInsightCredentialStore(secret, endpoint, legacyCredentials = null)

        try {
            store.saveCredential("openai", "fake-user-key")
            fail("Expected saveCredential to reject failed secure storage writes")
        } catch (error: IllegalStateException) {
            assertTrue(error.message?.contains("securely") == true)
        }

        assertFalse(secret.values.containsKey("credential.openai"))
    }
}

private class FakeInsightStringStorage(
    vararg initialValues: Pair<String, String>,
    private val failWrites: Boolean = false,
) : AndroidInsightStringStorage {
    val values: MutableMap<String, String> = linkedMapOf(*initialValues)

    override fun getString(key: String): String? = values[key]

    override fun putString(key: String, value: String): Boolean {
        if (failWrites) return false
        values[key] = value
        return true
    }

    override fun remove(key: String): Boolean {
        values.remove(key)
        return true
    }

    override fun keys(): Set<String> = values.keys.toSet()
}
