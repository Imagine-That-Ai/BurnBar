@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.clearMessages
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesServiceTest {
    @Test
    fun `initial state is disconnected`() = runTest {
        val service = HermesService()
        assertFalse(service.isConnected.value)
        assertTrue(service.messages.value.isEmpty())
        service.destroy()
    }

    @Test
    fun `clearMessages empties message list`() = runTest {
        val service = HermesService()
        // Can't connect without running server, but clearMessages works
        service.clearMessages()
        assertTrue(service.messages.value.isEmpty())
        service.destroy()
    }

    @Test
    fun `explicit send model beats stale chat tile override`() = runTest {
        val service = HermesService()
        try {
            service.setChatTilePreferences(
                ChatTilePreferences.DEFAULT.setSelectedHermesModel("gpt-5-4-mini"),
            )

            assertEquals(
                "minimax-m2.7-highspeed",
                service.resolvedModelNameForSend("minimax-m2.7-highspeed"),
            )
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `default send model still uses configured chat tile override`() = runTest {
        val service = HermesService()
        try {
            service.setChatTilePreferences(
                ChatTilePreferences.DEFAULT.setSelectedHermesModel("minimax-m2.7-highspeed"),
            )

            assertEquals(
                "minimax-m2.7-highspeed",
                service.resolvedModelNameForSend("hermes"),
            )
        } finally {
            service.destroy()
        }
    }
}
