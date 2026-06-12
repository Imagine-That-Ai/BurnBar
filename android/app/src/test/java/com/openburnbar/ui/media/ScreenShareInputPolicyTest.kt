// UI unit-test fixture literals (sizes, millis, colors); extraction adds noise without reuse.

package com.openburnbar.ui.media

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import com.openburnbar.data.media.VideoReceivePipeline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenShareInputPolicyTest {
    @Test
    fun touchTapUsesPrimaryClickAndLongPressUsesSecondaryClick() {
        assertEquals(0, ScreenMirrorInputPolicy.controlClickMouseButton(heldMillis = 80))
        assertEquals(
            1,
            ScreenMirrorInputPolicy.controlClickMouseButton(
                heldMillis = ScreenMirrorInputPolicy.RIGHT_CLICK_HOLD_MILLIS,
            ),
        )
    }

    @Test
    fun trackpadTapClicksImmediatelyButDragDoesNot() {
        assertEquals(
            0,
            ScreenMirrorInputPolicy.trackpadClickMouseButton(
                heldMillis = 80,
                travelDistancePx = ScreenMirrorInputPolicy.TRACKPAD_TAP_TRAVEL_LIMIT_PX - 0.1f,
            ),
        )
        assertNull(
            ScreenMirrorInputPolicy.trackpadClickMouseButton(
                heldMillis = 80,
                travelDistancePx = ScreenMirrorInputPolicy.TRACKPAD_TAP_TRAVEL_LIMIT_PX,
            ),
        )
    }

    @Test
    fun normalizedPointUsesRenderedMirrorBounds() {
        val root = IntSize(width = 400, height = 300)
        val aspect = 2f

        assertEquals(
            Pair(0.5, 0.5),
            ScreenMirrorInputPolicy.normalizedPoint(
                position = Offset(200f, 150f),
                rootSize = root,
                fit = ScreenMirrorFit.FIT,
                aspect = aspect,
            ),
        )
        assertNull(
            ScreenMirrorInputPolicy.normalizedPoint(
                position = Offset(200f, 40f),
                rootSize = root,
                fit = ScreenMirrorFit.FIT,
                aspect = aspect,
            ),
        )
    }

    @Test
    fun cursorStartsCenteredAndClampsInsideVideoBounds() {
        val root = IntSize(width = 400, height = 300)
        val aspect = 2f

        assertEquals(
            Offset(200f, 150f),
            ScreenMirrorInputPolicy.initialCursorPoint(root, ScreenMirrorFit.FIT, aspect),
        )
        assertEquals(
            Offset(0f, 250f),
            ScreenMirrorInputPolicy.movedCursorPoint(
                current = null,
                delta = Offset(-1_000f, 1_000f),
                rootSize = root,
                fit = ScreenMirrorFit.FIT,
                aspect = aspect,
            ),
        )
    }

    @Test
    fun staleFrameWithFreshMacHeartbeatDoesNotAskUserToRetry() {
        val stats =
            VideoReceivePipeline.Stats(
                widthPx = 1920,
                heightPx = 1080,
                queuedFrameCount = 12,
                lastFrameAtMillis = 1_000L,
            )

        assertFalse(
            screenShareNeedsAutomaticRecovery(
                phase = VideoReceivePipeline.Phase.Running(VideoReceivePipeline.Codec.HEVC),
                stats = stats,
                nowMillis = 20_000L,
                lastPeerHeartbeatAtMillis = 19_000L,
            ),
        )
        assertNull(
            screenShareStatusText(
                phase = VideoReceivePipeline.Phase.Running(VideoReceivePipeline.Codec.HEVC),
                stats = stats,
                nowMillis = 20_000L,
                lastPeerHeartbeatAtMillis = 19_000L,
            ),
        )
    }

    @Test
    fun staleFrameWithoutMacHeartbeatRecoversAutomatically() {
        val stats =
            VideoReceivePipeline.Stats(
                widthPx = 1920,
                heightPx = 1080,
                queuedFrameCount = 12,
                lastFrameAtMillis = 1_000L,
            )

        assertTrue(
            screenShareNeedsAutomaticRecovery(
                phase = VideoReceivePipeline.Phase.Running(VideoReceivePipeline.Codec.HEVC),
                stats = stats,
                nowMillis = 20_000L,
                lastPeerHeartbeatAtMillis = 0L,
            ),
        )
        assertEquals(
            "Mac video is recovering automatically...",
            screenShareStatusText(
                phase = VideoReceivePipeline.Phase.Running(VideoReceivePipeline.Codec.HEVC),
                stats = stats,
                nowMillis = 20_000L,
                lastPeerHeartbeatAtMillis = 0L,
            ),
        )
    }

    @Test
    fun remoteKeyboardDiffExtractsInsertedAndDeletedText() {
        assertEquals(
            RemoteKeyboardDiff(insertedText = "lo", deletedCount = 0),
            remoteKeyboardDiff(oldText = "hel", newText = "hello"),
        )
        assertEquals(
            RemoteKeyboardDiff(insertedText = "", deletedCount = 2),
            remoteKeyboardDiff(oldText = "hello", newText = "hel"),
        )
        assertEquals(
            RemoteKeyboardDiff(insertedText = "p", deletedCount = 1),
            remoteKeyboardDiff(oldText = "cat", newText = "cap"),
        )
    }

    @Test
    fun remoteKeyboardDispatchRoutesControlKeysSeparatelyFromText() {
        val events = mutableListOf<String>()

        dispatchRemoteKeyboardText(
            text = "hi\tthere\n",
            onText = { events += "text:$it" },
            onKey = { events += "key:$it" },
        )

        assertEquals(
            listOf("text:hi", "key:tab", "text:there", "key:return"),
            events,
        )
    }

    @Test
    fun viewerDestroyOnlyStopsMirrorForExplicitFinish() {
        assertTrue(
            shouldStopMirrorOnViewerDestroy(
                isFinishing = true,
                isChangingConfigurations = false,
            ),
        )
        assertFalse(
            shouldStopMirrorOnViewerDestroy(
                isFinishing = false,
                isChangingConfigurations = false,
            ),
        )
        assertFalse(
            shouldStopMirrorOnViewerDestroy(
                isFinishing = true,
                isChangingConfigurations = true,
            ),
        )
    }
}
