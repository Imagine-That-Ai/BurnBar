
package com.openburnbar

import com.openburnbar.data.policy.MobileAuthErrorClass
import com.openburnbar.data.policy.MobileAuthSessionPolicy
import com.openburnbar.data.policy.MobileAuthSessionState
import com.openburnbar.data.policy.UidScopedCacheRegistry
import com.openburnbar.data.stores.AuthStore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AuthStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `initial state reflects Firebase auth`() = runTest {
        val store = AuthStore(authProvider = { null }, firebaseAvailableOverride = true)
        assertFalse(store.isSignedIn.value)
        assertNull(store.userDisplayName.value)
        assertNull(store.userEmail.value)
        assertEquals(MobileAuthSessionState.SIGNED_OUT, store.sessionState.value)
    }

    @Test
    fun `firebase unavailable is not signed out`() {
        val store = AuthStore(authProvider = { null }, firebaseAvailableOverride = false)
        assertEquals(MobileAuthSessionState.FIREBASE_UNAVAILABLE, store.sessionState.value)
        assertNotEquals(MobileAuthSessionState.SIGNED_OUT, store.sessionState.value)
        assertFalse(store.sessionState.value.isSignedIn)
    }

    @Test
    fun `sign out clears scoped caches`() = runTest {
        val caches = UidScopedCacheRegistry()
        var cleared = 0
        caches.register { cleared += 1 }
        val store = AuthStore(
            authProvider = { null },
            scopedCaches = caches,
            firebaseAvailableOverride = true,
        )
        store.applyUid("uid-a")
        val previous = store.sessionEpoch.value
        store.signOut()
        advanceUntilIdle()
        assertTrue(cleared >= 1)
        assertFalse(MobileAuthSessionPolicy.isCurrent(previous, store.sessionEpoch.value))
        assertEquals(MobileAuthSessionState.SIGNED_OUT, store.sessionState.value)
    }

    @Test
    fun `account switch does not serve previous uid`() {
        val caches = UidScopedCacheRegistry()
        var cleared = 0
        caches.register { cleared += 1 }
        val store = AuthStore(
            authProvider = { null },
            scopedCaches = caches,
            firebaseAvailableOverride = true,
        )
        store.applyUid("uid-a")
        val previous = store.sessionEpoch.value
        store.applyUid("uid-b")
        assertEquals(MobileAuthErrorClass.ACCOUNT_SWITCH, store.lastErrorClass.value)
        assertTrue(cleared >= 1)
        assertFalse(MobileAuthSessionPolicy.shouldServeCachedData("uid-a", "uid-b", previous.generation, store.sessionEpoch.value.generation))
    }

    @Test
    fun `app check failure is a distinct class`() {
        val store = AuthStore(authProvider = { null }, firebaseAvailableOverride = true)
        store.applyError("app-check-failed", "Firebase App Check token is invalid.")
        assertEquals(MobileAuthErrorClass.APP_CHECK, store.lastErrorClass.value)
        assertNotEquals(MobileAuthErrorClass.PERMISSION_DENIED, store.lastErrorClass.value)
        assertNotEquals(MobileAuthSessionState.FIREBASE_UNAVAILABLE, store.sessionState.value)
    }
}
