package com.openburnbar.ui.hermes

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CliAgentRelayFallbackTest {
    @Test
    fun timeoutDoesNotStartASecondMission() {
        assertFalse(shouldFallBackToMissionAfterRelayError(RuntimeException("timeout waiting for Mac")))
        assertFalse(shouldFallBackToMissionAfterRelayError(RuntimeException("timed out")))
        assertFalse(shouldFallBackToMissionAfterRelayError(RuntimeException("already responding")))
        assertTrue(shouldFallBackToMissionAfterRelayError(RuntimeException("not connected")))
        assertTrue(shouldFallBackToMissionAfterRelayError(RuntimeException("Mac offline")))
    }
}
