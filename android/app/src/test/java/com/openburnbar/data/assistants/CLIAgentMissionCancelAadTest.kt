package com.openburnbar.data.assistants

import org.junit.Assert.assertEquals
import org.junit.Test

class CLIAgentMissionCancelAadTest {
    @Test
    fun cancelStateAadCapturesPathBoundContext() {
        val ctx = missionStateAadContext("alice", "req-1")
        val context = requireNotNull(ctx)
        val key = ByteArray(32) { 0x5A }
        val payload = cancelCallableSealedStatePayload("alice", "req-1", key)
        assertEquals(context.stringValue, payload["aad"])
        assertEquals("cli_agent_mission_requests", context.collection)
        assertEquals("req-1", context.docID)
        assertEquals("sealedStatePayload", context.field)
    }
}
