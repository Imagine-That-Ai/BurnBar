package com.openburnbar.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileBackdropKernelTest {
    @Test
    fun `kernel ids match the app burnbar ai registry order`() {
        assertEquals(
            listOf(
                "constellation",
                "flow",
                "aurora",
                "mesh",
                "moire",
                "volumetric",
                "lic",
                "fluid-aurora",
                "cloudfield",
                "plasma-orbs",
                "blobs-mesh",
                "retro-plasma",
                "inversion-lattice",
                "vogel-bloom",
                "crystal-drift",
                "ripple-lattice",
                "liquid-lumen",
                "spectral-drift",
                "mycelium-mesh",
                "oilfield",
                "suminagashi-drift",
                "kinetic-stipple",
                "neural-bloom",
                "agent1",
                "aether-lattice",
                "bat-signal",
                "storm-signal",
                "origami",
                "ink-diffusion",
                "petroleum-sheen",
            ),
            MobileBackdropKernel.websiteKernelIds,
        )
    }

    @Test
    fun `default matches app burnbar ai persisted backdrop default`() {
        assertEquals(MobileBackdropKernel.FLUID_AURORA, MobileBackdropKernel.DEFAULT)
        assertEquals("fluid-aurora", MobileBackdropKernel.DEFAULT.key)
    }

    @Test
    fun `fromKey round trips every kernel and rejects invalid keys`() {
        for (kernel in MobileBackdropKernel.entries) {
            assertEquals(kernel, MobileBackdropKernel.fromKey(kernel.key))
        }
        assertNull(MobileBackdropKernel.fromKey(null))
        assertNull(MobileBackdropKernel.fromKey(""))
        assertNull(MobileBackdropKernel.fromKey("not-a-kernel"))
        assertEquals(MobileBackdropKernel.DEFAULT, MobileBackdropKernel.resolved("not-a-kernel"))
    }

    @Test
    fun `labels and blurbs are populated for picker rendering`() {
        for (kernel in MobileBackdropKernel.entries) {
            assertTrue(kernel.displayName.isNotBlank())
            assertTrue(kernel.blurb.isNotBlank())
            assertNotEquals(kernel.key, kernel.displayName)
        }
    }
}
