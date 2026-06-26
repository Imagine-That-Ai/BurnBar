package com.openburnbar.diagnostics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class InMemoryBooleanPreferenceStorage : BooleanPreferenceStorage {
    private val values = mutableMapOf<String, Boolean>()

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean = values[key] ?: defaultValue

    override fun putBoolean(key: String, value: Boolean) {
        values[key] = value
    }
}

class CrashReportingConsentStoreTest {
    @Test
    fun `fresh installs keep crash reporting dark by default`() {
        val store = CrashReportingConsentStore(InMemoryBooleanPreferenceStorage())

        assertFalse(store.isEnabled)
    }

    @Test
    fun `granted consent persists as enabled`() {
        val storage = InMemoryBooleanPreferenceStorage()
        val store = CrashReportingConsentStore(storage)

        store.setEnabled(true)

        assertTrue(CrashReportingConsentStore(storage).isEnabled)
    }

    @Test
    fun `revoked consent persists as disabled`() {
        val storage = InMemoryBooleanPreferenceStorage()
        val store = CrashReportingConsentStore(storage)

        store.setEnabled(true)
        store.setEnabled(false)

        assertFalse(CrashReportingConsentStore(storage).isEnabled)
    }
}
