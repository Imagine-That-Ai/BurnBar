package com.openburnbar.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SettingsConnectedDevicesNavigationTest {
    @Test
    fun `settings row and search manifest route to connected devices`() {
        val router = SettingsRouter()
        val row =
            buildSettingsSystemGroup(router, onComputerUse = null)
                .firstOrNull { it.anchor == SettingsAnchor.CONNECTED_DEVICES }
        assertNotNull(row)
        assertEquals(SettingsPageRoute.CONNECTED_DEVICES, row?.pageRoute)

        row?.onTap?.invoke()

        assertEquals(SettingsPageRoute.CONNECTED_DEVICES, router.page)
        val manifestItem =
            SettingsManifest.all.first { it.anchorId == SettingsAnchor.CONNECTED_DEVICES }
        assertEquals(SettingsPageRoute.CONNECTED_DEVICES, manifestItem.pageRoute)
        assertEquals(
            SettingsPageRoute.CONNECTED_DEVICES,
            SettingsManifest.anchorIndex[SettingsAnchor.CONNECTED_DEVICES],
        )
    }
}
