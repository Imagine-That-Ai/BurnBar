package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JitterBufferTest {

    private fun frame(index: UInt) = MediaFrame(
        kind = MediaFrame.Kind.AUDIO_OPUS,
        frameIndex = index,
    )

    @Test
    fun pop_returns_null_until_target_size_reached() {
        val buffer = JitterBuffer(targetSize = 3)
        assertTrue(buffer.push(frame(1u)))
        assertTrue(buffer.push(frame(2u)))
        assertNull(buffer.popNext())
        assertTrue(buffer.push(frame(3u)))
        assertEquals(1u, buffer.popNext()?.frameIndex)
    }

    @Test
    fun reorders_out_of_order_arrivals() {
        val buffer = JitterBuffer(targetSize = 2)
        buffer.push(frame(5u))
        buffer.push(frame(3u))
        assertEquals(3u, buffer.popNext()?.frameIndex)
        // After popping (3) the queue has size 1 < target, so the next
        // pop blocks until another frame lands.
        assertNull(buffer.popNext())
        buffer.push(frame(4u))
        assertEquals(4u, buffer.popNext()?.frameIndex)
    }

    @Test
    fun stale_frames_are_dropped() {
        val buffer = JitterBuffer(targetSize = 2)
        buffer.push(frame(10u))
        buffer.push(frame(11u))
        assertEquals(10u, buffer.popNext()?.frameIndex)
        // 7 is older than 10 — should be rejected.
        assertFalse(buffer.push(frame(7u)))
    }

    @Test
    fun max_size_evicts_oldest_to_make_room() {
        val buffer = JitterBuffer(targetSize = 1, maxSize = 3)
        buffer.push(frame(1u))
        buffer.push(frame(2u))
        buffer.push(frame(3u))
        // Already at max — pushing a fresh frame must evict the oldest.
        buffer.push(frame(4u))
        // The buffer popped the oldest (1) to make room — calling popNext
        // returns the next-oldest (2).
        assertEquals(2u, buffer.popNext()?.frameIndex)
    }

    @Test
    fun clear_resets_high_watermark() {
        val buffer = JitterBuffer(targetSize = 1)
        buffer.push(frame(20u))
        assertEquals(20u, buffer.popNext()?.frameIndex)
        buffer.clear()
        // After clear, a frame older than the previous popped index should
        // be accepted again.
        assertTrue(buffer.push(frame(5u)))
        assertEquals(5u, buffer.popNext()?.frameIndex)
    }
}
