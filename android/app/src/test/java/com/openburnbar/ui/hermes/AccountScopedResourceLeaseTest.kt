package com.openburnbar.ui.hermes

import org.junit.Assert.assertEquals
import org.junit.Test

class AccountScopedResourceLeaseTest {
    @Test
    fun closeDisposesResourceExactlyOnce() {
        val disposed = mutableListOf<FakeResource>()
        val resource = FakeResource(uid = "uid-a")
        val lease = AccountScopedResourceLease(accountUid = resource.uid, resource = resource)

        lease.close(disposed::add)
        lease.close(disposed::add)

        assertEquals("uid-a", lease.accountUid)
        assertEquals(listOf(resource), disposed)
    }

    private data class FakeResource(val uid: String)
}
