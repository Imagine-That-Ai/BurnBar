package com.openburnbar.ui.media

import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import io.mockk.mockk
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class ScreenShareViewerControlSenderReuseTest {
    @Test
    fun `two sequential TYPE intents reuse the sender bound to the live control seal`() {
        val sender = mockk<PhoneControlSender>()
        val intents = listOf(PhoneControlIntentKind.TYPE, PhoneControlIntentKind.TYPE)

        val senders =
            intents.map {
                reusablePhoneControlSender(
                    sender = sender,
                    senderConnectionID = "connection-live",
                    activeConnectionID = "connection-live",
                    senderSealed = true,
                    activeSealPresent = true,
                )
            }

        senders.forEach { assertSame(sender, it) }
    }

    @Test
    fun `cached sender is rebuilt when the live seal mode changes`() {
        val sender = mockk<PhoneControlSender>()

        val reusable =
            reusablePhoneControlSender(
                sender = sender,
                senderConnectionID = "connection-live",
                activeConnectionID = "connection-live",
                senderSealed = true,
                activeSealPresent = false,
            )

        assertNull(reusable)
    }
}
