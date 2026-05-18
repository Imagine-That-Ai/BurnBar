package com.openburnbar.data.media

import java.util.PriorityQueue

/**
 * Adaptive jitter buffer for inbound audio. 1:1 port of the iOS
 * `JitterBuffer` (master plan § E.7). Holds up to `targetSize` audio
 * frames (default 60 ms / 3 packets at 20 ms each) so the decoder
 * receives them in monotonic frame-index order even when the network
 * delivers them out of sequence.
 *
 * Frames with a `frameIndex` older than the highest already-popped
 * index are dropped — they would create a discontinuity that the Opus
 * PLC handles cleanly via concealment.
 */
class JitterBuffer(
    val targetSize: Int = 3,
    val maxSize: Int = 16,
) {
    private val queue: PriorityQueue<MediaFrame> =
        PriorityQueue(maxSize) { a, b -> a.frameIndex.compareTo(b.frameIndex) }
    private var highestPoppedIndex: UInt? = null

    /** Insert one frame. Returns `true` if the frame was kept, `false` if dropped as stale. */
    fun push(frame: MediaFrame): Boolean {
        val highest = highestPoppedIndex
        if (highest != null && frame.frameIndex <= highest) return false
        if (queue.size >= maxSize) {
            // Drop the oldest queued frame to make room — never let the buffer grow without bound.
            queue.poll()
        }
        queue.add(frame)
        return true
    }

    /**
     * Returns the next frame the decoder should process, or `null` when
     * the buffer hasn't yet reached its target size. Consumers should
     * call this in a 20 ms loop matching the Opus frame cadence.
     */
    fun popNext(): MediaFrame? {
        if (queue.size < targetSize) return null
        val frame = queue.poll() ?: return null
        highestPoppedIndex = frame.frameIndex
        return frame
    }

    fun clear() {
        queue.clear()
        highestPoppedIndex = null
    }

    val size: Int get() = queue.size
}
