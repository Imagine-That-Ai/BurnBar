package com.openburnbar.data.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PensieveVectorCloakTest {
    @Test
    fun deterministicEmbed_is384DimAndStable() {
        val a = PensieveVectorCloak.deterministicEmbed("scaling vector search", isQuery = true)
        val b = PensieveVectorCloak.deterministicEmbed("scaling vector search", isQuery = true)
        assertEquals(PensieveVectorCloak.EMBEDDING_DIM, a.size)
        assertTrue(a.contentEquals(b))
    }

    @Test
    fun cloak_isVaultKeyed() {
        val keyA = ByteArray(32) { it.toByte() }
        val keyB = ByteArray(32) { (it + 1).toByte() }
        val raw = PensieveVectorCloak.deterministicEmbed("private launch plan")
        val cloakedA = PensieveVectorCloak.cloak(raw, keyA)
        val cloakedB = PensieveVectorCloak.cloak(raw, keyB)
        assertEquals(PensieveVectorCloak.EMBEDDING_DIM, cloakedA.size)
        assertNotEquals(cloakedA, cloakedB)
    }
}
