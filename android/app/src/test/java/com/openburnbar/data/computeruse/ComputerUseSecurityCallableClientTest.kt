
package com.openburnbar.data.computeruse

import com.google.firebase.functions.FirebaseFunctions
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ComputerUseSecurityCallableClientTest {
    @Test
    fun requireOk_acceptsSuccessfulCallablePayload() {
        val client = ComputerUseSecurityCallableClient(mockk<FirebaseFunctions>(relaxed = true))
        val method =
            ComputerUseSecurityCallableClient::class.java.getDeclaredMethod(
                "requireOk",
                Any::class.java,
                String::class.java,
            )
        method.isAccessible = true
        method.invoke(client, mapOf("ok" to true), "failure")
    }

    @Test
    fun providerAccountSubjectId_matchesServerAccountIDForDefault() {
        val client = ComputerUseSecurityCallableClient(mockk<FirebaseFunctions>(relaxed = true))
        assertEquals("codex_default", client.providerAccountSubjectId("codex", null))
        assertEquals("work-account", client.providerAccountSubjectId("anthropic", "Work Account"))
    }

    @Test
    fun requireOk_rejectsMissingOkFlag() {
        val client = ComputerUseSecurityCallableClient(mockk<FirebaseFunctions>(relaxed = true))
        val method =
            ComputerUseSecurityCallableClient::class.java.getDeclaredMethod(
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

    @Test
    fun routeCallable_rejectsAccountReplacementBeforeReturningResponse() = runTest {
        var currentUid = "uid-a"
        val callableStarted = CompletableDeferred<Unit>()
        val releaseCallable = CompletableDeferred<Unit>()

        val pending = async {
            runCatching {
                callBoundToExpectedUid(expectedUid = "uid-a", currentUidProvider = { currentUid }) {
                    callableStarted.complete(Unit)
                    releaseCallable.await()
                    "server-response"
                }
            }
        }
        callableStarted.await()
        currentUid = "uid-b"
        releaseCallable.complete(Unit)
        val outcome = pending.await()

        assertTrue(outcome.exceptionOrNull() is IllegalStateException)
        assertEquals(
            "The signed-in account changed during this Computer Use security action.",
            outcome.exceptionOrNull()?.message,
        )
    }
}
