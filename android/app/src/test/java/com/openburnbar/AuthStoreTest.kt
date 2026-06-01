@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.stores.AuthStore
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
