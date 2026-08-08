package com.openburnbar.ui.components

import com.openburnbar.ui.theme.AuroraColors
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Nav-tray contract for the AI Inbox destination: the enum label stays
 * routing-stable, the tray label reads "Inbox", and the accent/gradient match
 * the ember-to-amber treatment the iOS tab bar uses.
 */
class AuroraNavDestinationTest {
    @Test
    fun inboxLabelsStayStable() {
        assertEquals("Inbox", AuroraNavDestination.INBOX.label)
        assertEquals("Inbox", AuroraNavDestination.INBOX.trayLabel)
    }

    @Test
    fun inboxAccentIsEmber() {
        assertEquals(AuroraColors.ember, AuroraNavDestination.INBOX.accent)
    }

    @Test
    fun inboxGradientRunsEmberToAmber() {
        assertEquals(
            listOf(AuroraColors.ember, AuroraColors.amber),
            AuroraNavDestination.INBOX.gradientColors,
        )
    }
}
