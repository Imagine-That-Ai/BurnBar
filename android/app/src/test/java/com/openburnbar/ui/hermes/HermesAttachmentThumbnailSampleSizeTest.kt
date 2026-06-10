package com.openburnbar.ui.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesAttachmentThumbnailSampleSizeTest {
    @Test
    fun smallImagesDecodeAtFullResolution() {
        // Anything already at or near the chip target must not be downsampled.
        assertEquals(1, attachmentThumbnailSampleSize(48, 48))
        assertEquals(1, attachmentThumbnailSampleSize(144, 144))
        assertEquals(1, attachmentThumbnailSampleSize(287, 287))
    }

    @Test
    fun twelveMegapixelPhotoIsAggressivelyDownsampled() {
        // 4000x3000 (12MP): short edge 3000 → 3000/16 = 187 >= 144, 3000/32 = 93 < 144.
        assertEquals(16, attachmentThumbnailSampleSize(4000, 3000))
        assertEquals(16, attachmentThumbnailSampleSize(3000, 4000))
    }

    @Test
    fun sampledShortEdgeNeverDropsBelowTheChipTarget() {
        // ContentScale.Crop fills the 48dp chip from the short edge; keep it >= target
        // so the chip never upscales, across a sweep of realistic camera sizes.
        val sizes = listOf(640 to 480, 1920 to 1080, 3024 to 4032, 4000 to 3000, 8000 to 6000)
        for ((width, height) in sizes) {
            val sampleSize = attachmentThumbnailSampleSize(width, height)
            assertTrue(
                "short edge of ${width}x$height / $sampleSize fell below target",
                minOf(width, height) / sampleSize >= ATTACHMENT_THUMBNAIL_TARGET_PX,
            )
        }
    }

    @Test
    fun sampleSizesArePowersOfTwo() {
        // BitmapFactory rounds inSampleSize down to a power of two; emit exact values
        // so the decoded size is predictable.
        val sizes = listOf(100 to 100, 600 to 400, 1920 to 1080, 4032 to 3024, 12000 to 9000)
        for ((width, height) in sizes) {
            val sampleSize = attachmentThumbnailSampleSize(width, height)
            assertEquals(0, sampleSize and (sampleSize - 1))
        }
    }

    @Test
    fun unknownBoundsFallBackToFullDecode() {
        // A failed inJustDecodeBounds pass leaves outWidth/outHeight at -1; the decode
        // must then behave exactly like the pre-sampling code path.
        assertEquals(1, attachmentThumbnailSampleSize(-1, -1))
        assertEquals(1, attachmentThumbnailSampleSize(0, 0))
        assertEquals(1, attachmentThumbnailSampleSize(4000, 0))
    }
}
