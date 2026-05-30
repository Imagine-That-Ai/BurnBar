package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ComputerUseSecurityCallableClientTest {
    @Test
    fun requireOk_acceptsSuccessfulCallablePayload() {
        val client = ComputerUseSecurityCallableClient()
        val method = ComputerUseSecurityCallableClient::class.java.getDeclaredMethod(
            "requireOk",
            Any::class.java,
            String::class.java,
        )
        method.isAccessible = true
        method.invoke(client, mapOf("ok" to true), "failure")
    }

    @Test
    fun requireOk_rejectsMissingOkFlag() {
        val client = ComputerUseSecurityCallableClient()
        val method = ComputerUseSecurityCallableClient::class.java.getDeclaredMethod(
            "requireOk",
            Any::class.java,
            String::class.java,
        )
        method.isAccessible = true
        try {
            method.invoke(client, mapOf("ok" to false), "Escrow device trust approval failed.")
            error("Expected invocation target exception")
        } catch (error: java.lang.reflect.InvocationTargetException) {
            assertTrue(error.cause is IllegalStateException)
            assertEquals(
                "Escrow device trust approval failed.",
                error.cause?.message,
            )
        }
    }
}
