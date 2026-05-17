package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ComputerUseWatchReducerTest {

    @Test
    fun approvalResponseClearsPendingAndAppendsAuditRow() {
        val reducer = ComputerUseWatchReducer()
        reducer.startSession("session-1", ComputerUseTrustMode.MANUAL)
        reducer.setPendingApproval(
            ComputerUseApprovalRequest(
                approvalId = "approval-1",
                sessionId = "session-1",
                toolKind = "browser.goto",
                actionSummary = "Open example.com",
                requestedAtMillis = 10L,
            )
        )

        val response = reducer.approve(nowMillis = 20L)
        val state = reducer.state.value

        assertEquals("approval-1", response?.approvalId)
        assertTrue(response?.approved == true)
        assertNull(state.pendingApproval)
        assertEquals(ComputerUseActionStatus.COMPLETED, state.latestAction?.status)
        assertEquals("Approved: Open example.com", state.latestAction?.summary)
    }

    @Test
    fun phoneCanOnlyDowngradeTrustMode() {
        val reducer = ComputerUseWatchReducer()
        reducer.startSession("session-1", ComputerUseTrustMode.STEP)

        reducer.downgradeTrustMode(ComputerUseTrustMode.TRUSTED)
        assertEquals(ComputerUseTrustMode.STEP, reducer.state.value.trustMode)

        reducer.downgradeTrustMode(ComputerUseTrustMode.MANUAL)
        assertEquals(ComputerUseTrustMode.MANUAL, reducer.state.value.trustMode)
    }

    @Test
    fun surfaceFrameStoresCursorMetadata() {
        val reducer = ComputerUseWatchReducer()
        val frame = MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            flags = MediaFrame.Flags.HAS_CURSOR_METADATA,
            cursor = MediaFrame.CursorMetadata(44, 88),
        )

        reducer.ingestFrame(frame, receivedAtMillis = 42L)

        assertEquals(frame, reducer.state.value.currentFrame)
        assertEquals(MediaFrame.CursorMetadata(44, 88), reducer.state.value.currentFrame?.cursor)
        assertEquals(42L, reducer.state.value.lastFrameReceivedAtMillis)
    }

    @Test
    fun rejectAndHaltMarksSessionPanicHalted() {
        val reducer = ComputerUseWatchReducer()
        reducer.startSession("session-1")
        reducer.setPendingApproval(
            ComputerUseApprovalRequest(
                approvalId = "approval-2",
                sessionId = "session-1",
                toolKind = "mac.input.click",
                actionSummary = "Click button",
                requestedAtMillis = 1L,
            )
        )

        val response = reducer.reject(halt = true, nowMillis = 2L)

        assertFalse(response?.approved == true)
        assertTrue(response?.halt == true)
        assertTrue(reducer.state.value.panicHalted)
        assertEquals(ComputerUseActionStatus.PANIC_HALTED, reducer.state.value.latestAction?.status)
    }
}

