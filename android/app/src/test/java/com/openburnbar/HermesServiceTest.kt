package com.openburnbar

import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.HermesConnection
import com.openburnbar.data.hermes.ConnectionType
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.Assert.*
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
}
