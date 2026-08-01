package com.openburnbar.data.media

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceLifecycleGateTest {
    @Test
    fun `old callback destroy cannot retire a replacement callback surface`() = runTest {
        val gate = SurfaceLifecycleGate<Any>()
        val oldSurface = Any()
        val replacementSurface = Any()

        gate.claim(oldSurface)
        val replacementStart = gate.claim(replacementSurface)

        assertNull(gate.retire(oldSurface))
        assertTrue(gate.runIfCurrent(replacementStart) {})
    }

    @Test
    fun `queued stale destroy cannot stop a replacement surface`() = runTest {
        val gate = SurfaceLifecycleGate<Any>()
        val oldSurface = Any()
        val replacementSurface = Any()
        val firstStartEntered = CompletableDeferred<Unit>()
        val releaseFirstStart = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()

        val firstStartToken = gate.claim(oldSurface)
        val firstStart =
            async {
                gate.runIfCurrent(firstStartToken) {
                    events += "start-old"
                    firstStartEntered.complete(Unit)
                    releaseFirstStart.await()
                }
            }
        firstStartEntered.await()

        val staleDestroy = gate.retire(oldSurface) ?: error("old surface should still own the pipeline")
        val replacementStartToken = gate.claim(replacementSurface)
        val destroy =
            async {
                gate.runIfCurrent(staleDestroy) {
                    events += "stop-old"
                }
            }
        val replacementStart =
            async {
                gate.runIfCurrent(replacementStartToken) {
                    events += "start-new"
                }
            }

        releaseFirstStart.complete(Unit)

        assertTrue(firstStart.await())
        assertFalse(destroy.await())
        assertTrue(replacementStart.await())
        assertEquals(listOf("start-old", "start-new"), events)
    }

    @Test
    fun `current destroy still stops when no replacement exists`() = runTest {
        val gate = SurfaceLifecycleGate<Any>()
        val surface = Any()
        gate.claim(surface)
        val destroy = gate.retire(surface) ?: error("current surface must retire")
        var stopped = false

        assertTrue(
            gate.runIfCurrent(destroy) {
                stopped = true
            },
        )
        assertTrue(stopped)
    }
}
