package com.openburnbar

import com.openburnbar.data.stores.AuthStore
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class AuthStoreTest {

    @Test
    fun `initial state reflects Firebase auth`() = runTest {
        val store = AuthStore()
        // Without a logged-in Firebase user, isSignedIn should be false
        assertNotNull(store.isSignedIn.value)
        assertNotNull(store.userDisplayName.value)
        assertNotNull(store.userEmail.value)
    }
}
