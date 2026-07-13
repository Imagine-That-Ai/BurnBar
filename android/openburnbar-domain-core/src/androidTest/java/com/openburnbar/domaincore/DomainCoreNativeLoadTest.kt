package com.openburnbar.domaincore

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion

@RunWith(AndroidJUnit4::class)
class DomainCoreNativeLoadTest {
    @Test
    fun generatedBindingLoadsAbiVersionTwoNativeLibrary() {
        assertEquals(2u, domainCoreAbiVersion())
        assertTrue(domainCoreVersion().isNotBlank())
    }
}
