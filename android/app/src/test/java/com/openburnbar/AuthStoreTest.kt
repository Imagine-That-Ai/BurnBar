package com.openburnbar

import com.openburnbar.data.stores.AuthStore
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class AuthStoreTest {

    @Test
    fun `initial state reflects Firebase auth`() = runTest {
        val store = AuthStore()
        assertFalse(store.isSignedIn.value)
        assertNull(store.userDisplayName.value)
        assertNull(store.userEmail.value)
    }
}
