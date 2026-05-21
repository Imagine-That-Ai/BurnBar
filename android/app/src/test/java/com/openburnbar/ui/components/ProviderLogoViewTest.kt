package com.openburnbar.ui.components

import com.openburnbar.R
import com.openburnbar.data.square.AgentIdentity
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderLogoViewTest {
    @Test
    fun pairedMacIdentityUsesDedicatedMacLogoInsteadOfHermesFallback() {
        val identity = AgentIdentity.pairedMacPlaceholder("device://paired-mac/relay-live")

        assertEquals(R.drawable.paired_mac_logo, ProviderLogo.drawableForIdentity(identity))
        assertEquals(R.drawable.paired_mac_logo, ProviderLogo.drawableForAnyIdentifier(identity.id))
    }
}
