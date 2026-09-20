package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaGOPTest {
    @Test
    fun dropsUnanchoredDeltaUntilKeyframe() {
        val window = MediaGOPReceiveWindow()
        assertEquals(
            MediaGOPReceiveWindow.Decision.DROP_UNANCHORED,
            window.admit(gopID = 3u, isKeyframe = false, isEndOfGroup = false),
        )
    }

    @Test
    fun newerKeyframeAbortsOlderGopFrames() {
        val window = MediaGOPReceiveWindow()
        assertEquals(MediaGOPReceiveWindow.Decision.DECODE, window.admit(5u, isKeyframe = true, isEndOfGroup = false))
        assertEquals(MediaGOPReceiveWindow.Decision.DECODE, window.admit(5u, isKeyframe = false, isEndOfGroup = false))
        assertEquals(MediaGOPReceiveWindow.Decision.DECODE, window.admit(6u, isKeyframe = true, isEndOfGroup = false))
        assertEquals(5u, window.highestCompletedGopID)
        assertEquals(MediaGOPReceiveWindow.Decision.DROP_STALE, window.admit(5u, isKeyframe = false, isEndOfGroup = true))
        assertEquals(MediaGOPReceiveWindow.Decision.DECODE, window.admit(6u, isKeyframe = false, isEndOfGroup = true))
    }

    @Test
    fun stamperMarksPreviousGopOnNextKeyframe() {
        val stamper = MediaGOPEndStamper()
        assertNull(stamper.push(MediaFrame(kind = MediaFrame.Kind.VIDEO_NAL, flags = MediaFrame.Flags.KEYFRAME, gopID = 1u)))

        val mid = MediaFrame(kind = MediaFrame.Kind.VIDEO_NAL, gopID = 1u, frameIndex = 1u)
        val first = stamper.push(mid)
        checkNotNull(first)
        assertTrue(MediaFrame.Flags.KEYFRAME in first.flags)
        assertFalse(MediaFrame.Flags.END_OF_GROUP in first.flags)

        val lastOfFirst =
            stamper.push(MediaFrame(kind = MediaFrame.Kind.VIDEO_NAL, flags = MediaFrame.Flags.KEYFRAME, gopID = 2u))
        checkNotNull(lastOfFirst)
        assertEquals(1u, lastOfFirst.gopID)
        assertTrue(MediaFrame.Flags.END_OF_GROUP in lastOfFirst.flags)
    }

    @Test
    fun bwePayloadRoundTrips() {
        val payload =
            MediaBweFeedbackPayload(
                roundTripMillis = 240,
                packetLossRate = 0.05,
                observedBitsPerSecond = 400_000,
                pathConstrained = true,
            )
        val decoded = MediaBweFeedbackPayload.decode(payload.encoded())
        assertEquals(payload, decoded)
        assertTrue(decoded.toSample().pathConstrained)
        assertTrue(MediaBweFeedbackPayload.isConstrainedPath(usesCellular = true, isExpensive = false, isConstrained = false))
    }
}
