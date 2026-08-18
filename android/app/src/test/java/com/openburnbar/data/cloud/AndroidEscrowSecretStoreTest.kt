package com.openburnbar.data.cloud

import org.junit.Assert.assertFalse
import org.junit.Test

class AndroidEscrowSecretStoreTest {
    @Test
    fun persistRejectsBlankProviderOrSecretWithoutTouchingStorage() {
        assertFalse(AndroidEscrowSecretStore.persist("", "secret"))
        assertFalse(AndroidEscrowSecretStore.persist("   ", "secret"))
        assertFalse(AndroidEscrowSecretStore.persist("openai", ""))
        assertFalse(AndroidEscrowSecretStore.persist("openai", "   "))
    }

    @Test
    fun persistFailsClosedWhenAppContextIsUninitialized() {
        assertFalse(AndroidEscrowSecretStore.persist("openai", "sk-test"))
    }
}
