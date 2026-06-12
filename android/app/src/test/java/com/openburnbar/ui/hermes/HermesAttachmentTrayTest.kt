// boundary fixtures are literal by design.

package com.openburnbar.ui.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Decode-budget tests for the `HermesAttachmentTray` thumbnail sampler:
 * [attachmentThumbnailSampleSize] must return the LARGEST power of two that
 * keeps the decoded short edge at or above the chip target — maximal memory
 * savings without ever upscaling. Complements the scenario sweep in
 * [HermesAttachmentThumbnailSampleSizeTest] with the exact boundary and a
 * brute-force maximality proof.
 */
class HermesAttachmentTrayTest {
    @Test
    fun `chip target is 48dp at 3x density`() {
        assertEquals(144, ATTACHMENT_THUMBNAIL_TARGET_PX)
    }

    @Test
    fun `doubling boundary flips exactly at twice the target`() {
        // 287: 287/2 = 143 < 144 → must stay at full decode.
        assertEquals(1, attachmentThumbnailSampleSize(287, 5000))
        // 288: 288/2 = 144 >= 144 → first halving is allowed.
        assertEquals(2, attachmentThumbnailSampleSize(288, 5000))
        // 575/4 = 143 < 144 → stays at 2; 576/4 = 144 → reaches 4.
        assertEquals(2, attachmentThumbnailSampleSize(575, 5000))
        assertEquals(4, attachmentThumbnailSampleSize(576, 5000))
    }

    @Test
    fun `sample size is always the maximal power of two above the target`() {
        // Brute-force reference: the largest power-of-two divisor that keeps
        // min(width, height)/sampleSize >= target.
        fun reference(width: Int, height: Int): Int {
            if (width <= 0 || height <= 0) return 1
            var candidate = 1
            while (minOf(width, height) / (candidate * 2) >= ATTACHMENT_THUMBNAIL_TARGET_PX) {
                candidate *= 2
            }
            return candidate
        }
        for (shortEdge in intArrayOf(1, 143, 144, 287, 288, 600, 1080, 2159, 2160, 3024, 4000, 8192)) {
            for (longEdge in intArrayOf(shortEdge, shortEdge * 2, shortEdge * 3 + 7)) {
                val expected = reference(longEdge, shortEdge)
                val actual = attachmentThumbnailSampleSize(longEdge, shortEdge)
                assertEquals("${longEdge}x$shortEdge", expected, actual)
                // Maximality: one more halving would drop under the target.
                if (shortEdge >= ATTACHMENT_THUMBNAIL_TARGET_PX) {
                    assertTrue(shortEdge / actual >= ATTACHMENT_THUMBNAIL_TARGET_PX)
                    assertTrue(shortEdge / (actual * 2) < ATTACHMENT_THUMBNAIL_TARGET_PX)
                }
            }
        }
    }

    @Test
    fun `orientation never changes the decode budget`() {
        for ((width, height) in listOf(4000 to 3000, 1920 to 1080, 640 to 480)) {
            assertEquals(
                attachmentThumbnailSampleSize(width, height),
                attachmentThumbnailSampleSize(height, width),
            )
        }
    }

    @Test
    fun `degenerate bounds decode at full resolution`() {
        assertEquals(1, attachmentThumbnailSampleSize(0, 4000))
        assertEquals(1, attachmentThumbnailSampleSize(4000, -1))
        assertEquals(1, attachmentThumbnailSampleSize(Int.MIN_VALUE, Int.MIN_VALUE))
    }
}
