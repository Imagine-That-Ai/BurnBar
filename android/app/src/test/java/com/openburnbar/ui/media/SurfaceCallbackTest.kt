package com.openburnbar.ui.media

import android.view.Surface
import android.view.SurfaceHolder
import com.openburnbar.data.media.SurfaceLifecycleGate
import com.openburnbar.data.media.VideoReceivePipeline
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SurfaceCallbackTest {
    @Test
    fun `surfaceCreated claims the surface and starts the pipeline`() = runTest {
        val gate = SurfaceLifecycleGate<Surface>()
        val surface = mockk<Surface>()
        val holder = holderFor(surface)
        val pipeline = pipelineWith(gate)
        val callback = SurfaceCallback(pipeline, this)

        callback.surfaceCreated(holder)
        advanceUntilIdle()

        coVerify(exactly = 1) { pipeline.start(surface, any(), any()) }
    }

    @Test
    fun `surfaceDestroyed retires the surface and stops the pipeline`() = runTest {
        val gate = SurfaceLifecycleGate<Surface>()
        val surface = mockk<Surface>()
        val holder = holderFor(surface)
        val pipeline = pipelineWith(gate)
        val callback = SurfaceCallback(pipeline, this)

        callback.surfaceCreated(holder)
        advanceUntilIdle()
        callback.surfaceDestroyed(holder)
        advanceUntilIdle()

        coVerify(exactly = 1) { pipeline.stop() }
    }

    @Test
    fun `surfaceDestroyed without an owning claim never stops the pipeline`() = runTest {
        val gate = SurfaceLifecycleGate<Surface>()
        val holder = holderFor(mockk())
        val pipeline = pipelineWith(gate)
        val callback = SurfaceCallback(pipeline, this)

        callback.surfaceDestroyed(holder)
        advanceUntilIdle()

        coVerify(exactly = 0) { pipeline.stop() }
    }

    @Test
    fun `stale destroy after a replacement surface claim never stops the pipeline`() = runTest {
        val gate = SurfaceLifecycleGate<Surface>()
        val oldSurface = mockk<Surface>()
        val replacementSurface = mockk<Surface>()
        val pipeline = pipelineWith(gate)
        val callback = SurfaceCallback(pipeline, this)

        callback.surfaceCreated(holderFor(oldSurface))
        advanceUntilIdle()
        callback.surfaceCreated(holderFor(replacementSurface))
        callback.surfaceDestroyed(holderFor(oldSurface))
        advanceUntilIdle()

        coVerify(exactly = 0) { pipeline.stop() }
        coVerify(exactly = 1) { pipeline.start(replacementSurface, any(), any()) }
    }

    @Test
    fun `surfaceChanged is a no-op`() = runTest {
        val gate = SurfaceLifecycleGate<Surface>()
        val surface = mockk<Surface>()
        val pipeline = pipelineWith(gate)
        val callback = SurfaceCallback(pipeline, this)

        callback.surfaceChanged(holderFor(surface), 0, 1, 1)
        advanceUntilIdle()

        coVerify(exactly = 0) { pipeline.start(any(), any(), any()) }
        coVerify(exactly = 0) { pipeline.stop() }
    }

    private fun holderFor(surface: Surface): SurfaceHolder {
        val holder = mockk<SurfaceHolder>()
        every { holder.surface } returns surface
        return holder
    }

    private fun pipelineWith(gate: SurfaceLifecycleGate<Surface>): VideoReceivePipeline {
        val pipeline = mockk<VideoReceivePipeline>()
        every { pipeline.surfaceLifecycleGate } returns gate
        coEvery { pipeline.start(any(), any(), any()) } returns Unit
        coEvery { pipeline.stop() } returns Unit
        return pipeline
    }
}
