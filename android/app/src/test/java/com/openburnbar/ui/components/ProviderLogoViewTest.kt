package com.openburnbar.ui.components

import com.openburnbar.R
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import com.openburnbar.data.square.AgentIdentity
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderLogoViewTest {
    @Test
    fun mimoProviderUsesDedicatedLogoAsset() {
        assertEquals(R.drawable.mimo_logo, ProviderLogo.drawableFor(AgentProvider.MIMO))
    }

    @Test
    fun warpResolvesToTheSingleDedupedLogoOnBothLookupSurfaces() {
        // The drawable/ + drawable-nodpi byte-identical pair was collapsed to one
        // nodpi copy; both lookup paths must share it so the APK never re-grows
        // a second warp bitmap.
        assertEquals(R.drawable.logo_warp, ProviderLogo.drawableFor(AgentProvider.WARP))
        assertEquals(R.drawable.logo_warp, AgentProvider.WARP.logoRes)
    }

    @Test
    fun pairedMacIdentityUsesDedicatedMacLogoInsteadOfHermesFallback() {
        val identity = AgentIdentity.pairedMacPlaceholder("device://paired-mac/relay-live")

        assertEquals(R.drawable.paired_mac_logo, ProviderLogo.drawableForIdentity(identity))
        assertEquals(R.drawable.paired_mac_logo, ProviderLogo.drawableForAnyIdentifier(identity.id))
    }
}
