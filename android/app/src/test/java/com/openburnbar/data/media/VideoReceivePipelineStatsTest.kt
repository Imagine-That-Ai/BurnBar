package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoReceivePipelineStatsTest {
    @Test
    fun recordsInboundBitrateOverRollingWindow() {
        val pipeline = VideoReceivePipeline()
        val start = 1_800_000_000_000L

        pipeline.noteAcceptedFrame(wireByteCount = 500_000, nowMillis = start)
        assertEquals(0, pipeline.stats.value.bitsPerSecond)

        pipeline.noteAcceptedFrame(wireByteCount = 500_000, nowMillis = start + 1_000)

        assertEquals(8_000_000, pipeline.stats.value.bitsPerSecond)
        assertEquals(2, pipeline.stats.value.queuedFrameCount)
        assertEquals(start + 1_000, pipeline.stats.value.lastFrameAtMillis)
    }

    @Test
    fun clampsRoundTripAndPreservesBitrate() {
        val pipeline = VideoReceivePipeline()
        val start = 1_800_000_000_000L
        pipeline.noteAcceptedFrame(wireByteCount = 250_000, nowMillis = start)
        pipeline.noteAcceptedFrame(wireByteCount = 250_000, nowMillis = start + 500)

        pipeline.updateRoundTripStats(rttMillis = -8, bitsPerSecond = -1)
        assertEquals(0, pipeline.stats.value.roundTripMillis)
        assertEquals(0, pipeline.stats.value.bitsPerSecond)

        pipeline.noteAcceptedFrame(wireByteCount = 500_000, nowMillis = start + 1_500)
        pipeline.updateRoundTripMillis(42)

        assertEquals(42, pipeline.stats.value.roundTripMillis)
        assertEquals(4_000_000, pipeline.stats.value.bitsPerSecond)
    }

    @Test
    fun estimatesWireByteCountsForStats() {
        val v1 = MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            flags = MediaFrame.Flags.HAS_CURSOR_METADATA,
            payload = ByteArray(12),
        )
        val v2 = MediaFrameV2(
            kind = MediaFrameV2Kind.VIDEO_NAL,
            metadata = ByteArray(5),
            payload = ByteArray(12),
        )

        assertEquals(
            MediaFrame.HEADER_BYTE_COUNT + MediaFrame.CURSOR_METADATA_BYTE_COUNT + 12,
            VideoReceivePipeline.estimatedWireByteCount(v1),
        )
        assertEquals(
            MediaFrameV2Codec.FIXED_HEADER_BYTE_COUNT + 5 + 12,
            VideoReceivePipeline.estimatedWireByteCount(v2),
        )
    }
}
