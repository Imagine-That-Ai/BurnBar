package com.openburnbar.data.computeruse

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-AND-05 — verifies the code-level coupling between BiometricPrompt success and reading the
 * Remote Unlock saved-credential store: a fresh, single-use authentication ticket is required, it
 * is consumed on use, and it expires. The AndroidKeyStore decrypt is the separate backstop; this
 * test pins the in-code gate that prevents a load() without a prior authenticateForRemoteUnlock.
 */
class RemoteUnlockSavedCredentialStoreAuthGateTest {
    private var now = 1_000_000L

    private fun newStore(): RemoteUnlockSavedCredentialStore {
        val prefs = mockk<SharedPreferences>(relaxed = true)
        val context = mockk<Context>(relaxed = true)
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns prefs
        return RemoteUnlockSavedCredentialStore(context) { now }
    }

    @Test
    fun noAuthenticationMeansNoFreshTicket() {
        val store = newStore()
        assertFalse("a brand-new store has no authentication ticket", store.hasFreshAuthentication())
        assertFalse("consuming an absent ticket is not fresh", store.consumeAuthenticationTicketForTest())
    }

    @Test
    fun successMintsAFreshTicket() {
        val store = newStore()
        store.recordAuthenticationSuccess()
        assertTrue(store.hasFreshAuthentication())
    }

    @Test
    fun ticketIsSingleUseAndConsumedOnLoad() {
        val store = newStore()
        store.recordAuthenticationSuccess()
        // First consume (what load() does) succeeds...
        assertTrue(store.consumeAuthenticationTicketForTest())
        // ...and the ticket is now gone, so a second read is refused.
        assertFalse(store.hasFreshAuthentication())
        assertFalse(store.consumeAuthenticationTicketForTest())
    }

    @Test
    fun ticketExpiresAfterValidityWindow() {
        val store = newStore()
        store.recordAuthenticationSuccess()
        now += RemoteUnlockSavedCredentialStore.AUTH_TICKET_VALIDITY_MILLIS + 1
        assertFalse("a ticket older than the validity window is refused", store.hasFreshAuthentication())
        assertFalse(store.consumeAuthenticationTicketForTest())
    }

    @Test
    fun ticketWithinWindowIsAccepted() {
        val store = newStore()
        store.recordAuthenticationSuccess()
        now += RemoteUnlockSavedCredentialStore.AUTH_TICKET_VALIDITY_MILLIS - 1
        assertTrue(store.hasFreshAuthentication())
    }
}
