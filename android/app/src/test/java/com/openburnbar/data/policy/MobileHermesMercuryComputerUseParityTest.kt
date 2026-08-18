package com.openburnbar.data.policy

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Shared Hermes / Mercury / Computer Use vectors. Source: iOS cancel + MercuryPeer. */
class MobileHermesMercuryComputerUseParityTest {
    @Test
    fun hermesStopMidStream() {
        assertStreamTerminal(hermesVector("hermes.stop-mid-stream"))
    }

    @Test
    fun hermesCancelVsError() {
        val vector = hermesVector("hermes.cancel-vs-error")
        val cancel = MobileHermesConversationPolicy.terminal(vector.getString("event"))
        val error = MobileHermesConversationPolicy.terminal(vector.getString("compareEvent"))
        val expected = vector.getJSONObject("expected")
        assertEquals(expected.getString("terminal"), cancel.wire)
        assertTrue(MobileHermesConversationPolicy.keepsPartial(cancel))
        assertFalse(MobileHermesConversationPolicy.marksError(cancel))
        assertEquals(expected.getString("compareTerminal"), error.wire)
        assertEquals(expected.getBoolean("compareIsError"), MobileHermesConversationPolicy.marksError(error))
        assertEquals(expected.getBoolean("compareKeepPartial"), MobileHermesConversationPolicy.keepsPartial(error))
        assertNotEquals(cancel, error)
    }

    @Test
    fun hermesPartialResultKept() {
        assertStreamTerminal(hermesVector("hermes.partial-result-kept"))
    }

    @Test
    fun hermesReconnectNoDuplicateUser() {
        val vector = hermesVector("hermes.reconnect-no-duplicate-user")
        assertEquals(
            vector.getJSONObject("expected").getBoolean("appendUser"),
            MobileHermesConversationPolicy.shouldAppendUserMessage(
                lastRole = vector.getString("lastRole"),
                lastText = vector.getString("lastText"),
                incomingText = vector.getString("incomingText"),
                reason = vector.getString("reason"),
            ),
        )
    }

    @Test
    fun hermesToolCallAfterStop() {
        val vector = hermesVector("hermes.tool-call-after-stop")
        val terminal = MobileHermesConversationPolicy.terminal(vector.getString("event"))
        val expected = vector.getJSONObject("expected")
        assertEquals(expected.getString("terminal"), terminal.wire)
        assertTrue(
            MobileHermesConversationPolicy.shouldRenderToolCalls(vector.getInt("toolCallCount"), terminal),
        )
        assertFalse(
            MobileHermesConversationPolicy.shouldDropEmptyAssistant(
                text = vector.getString("text"),
                toolCallCount = vector.getInt("toolCallCount"),
                isError = vector.getBoolean("isError"),
                terminal = terminal,
            ),
        )
    }

    @Test
    fun hermesAttachmentMalformedRejected() {
        val vector = hermesVector("hermes.attachment-malformed-rejected")
        assertEquals(
            vector.getJSONObject("expected").getString("disposition"),
            MobileHermesConversationPolicy.attachmentDisposition(
                id = vector.getString("attachmentId"),
                mimeType = vector.getString("mimeType"),
                byteSize = vector.getInt("byteSize"),
                path = vector.getString("path"),
            ).wire,
        )
    }

    @Test
    fun hermesDeepLinkMissingConversation() {
        val vector = hermesVector("hermes.deep-link-missing-conversation")
        val outcome = MobileHermesConversationPolicy.conversationDeepLink(
            threadId = vector.getString("threadId"),
            exists = vector.getBoolean("exists"),
        )
        assertEquals(vector.getJSONObject("expected").getString("outcome"), outcome.wire)
        assertEquals(
            vector.getJSONObject("expected").getString("message"),
            MobileHermesConversationPolicy.missingConversationMessage(outcome),
        )
    }

    @Test
    fun hermesThreadIsolationLateChunk() {
        val vector = hermesVector("hermes.thread-isolation-late-chunk")
        assertFalse(
            MobileHermesConversationPolicy.shouldApplyChunk(
                chunkThreadId = vector.getString("chunkThreadId"),
                activeThreadId = vector.getString("activeThreadId"),
                chunkGeneration = vector.getInt("chunkGeneration"),
                activeGeneration = vector.getInt("activeGeneration"),
            ),
        )
    }

    @Test
    fun mercuryHeartbeatInterval60s() {
        val vector = hermesVector("mercury.heartbeat-interval-60s")
        assertEquals(
            vector.getJSONObject("expected").getLong("intervalMs"),
            MobileMercuryMediaPolicy.HEARTBEAT_INTERVAL_MS,
        )
    }

    @Test
    fun mercuryUnknownCapabilityFiltered() {
        val vector = hermesVector("mercury.unknown-capability-filtered")
        assertEquals(
            expectedStringList(vector.getJSONObject("expected").getJSONArray("capabilities")),
            MobileMercuryMediaPolicy.filterCapabilities(expectedStringList(vector.getJSONArray("raw"))),
        )
    }

    @Test
    fun mercuryInviteAckPairing() {
        val vector = hermesVector("mercury.invite-ack-pairing")
        assertEquals(
            vector.getJSONObject("expected").getString("pair"),
            MobileMercuryMediaPolicy.inviteAckPair(
                inviteId = vector.getString("inviteId"),
                ackId = vector.getString("ackId"),
                accepted = vector.getBoolean("accepted"),
            ).wire,
        )
    }

    @Test
    fun mercuryDenialNotConnected() {
        val vector = hermesVector("mercury.denial-not-connected")
        assertEquals(
            vector.getJSONObject("expected").getString("presentation"),
            MobileMercuryMediaPolicy.sessionPresentation(
                phase = vector.getString("phase"),
                denied = vector.getBoolean("denied"),
            ).wire,
        )
        assertNotEquals(
            MobileMercurySessionPresentation.CONNECTED,
            MobileMercuryMediaPolicy.sessionPresentation(phase = "live", denied = true),
        )
    }

    @Test
    fun mercuryReconnect() {
        val vector = hermesVector("mercury.reconnect")
        assertEquals(
            vector.getJSONObject("expected").getString("presentation"),
            MobileMercuryMediaPolicy.sessionPresentation(
                phase = vector.getString("phase"),
                denied = vector.getBoolean("denied"),
            ).wire,
        )
    }

    @Test
    fun computerUseReplayRejected() {
        assertSafety(hermesVector("computeruse.replay-rejected"))
    }

    @Test
    fun computerUseTamperRejected() {
        assertSafety(hermesVector("computeruse.tamper-rejected"))
    }

    @Test
    fun computerUseExpiredGrantRejected() {
        assertSafety(hermesVector("computeruse.expired-grant-rejected"))
    }

    @Test
    fun computerUseUnauthenticatedSenderRejected() {
        assertSafety(hermesVector("computeruse.unauthenticated-sender-rejected"))
    }

    @Test
    fun computerUseBindingMismatchRejected() {
        assertSafety(hermesVector("computeruse.binding-mismatch-rejected"))
    }

    private fun assertStreamTerminal(vector: JSONObject) {
        val terminal = MobileHermesConversationPolicy.terminal(vector.getString("event"))
        val expected = vector.getJSONObject("expected")
        assertEquals(expected.getString("terminal"), terminal.wire)
        assertEquals(expected.getBoolean("keepPartial"), MobileHermesConversationPolicy.keepsPartial(terminal))
        assertEquals(expected.getBoolean("isError"), MobileHermesConversationPolicy.marksError(terminal))
        if (expected.has("dropEmptyAssistant")) {
            assertEquals(
                expected.getBoolean("dropEmptyAssistant"),
                MobileHermesConversationPolicy.shouldDropEmptyAssistant(
                    text = vector.getString("text"),
                    toolCallCount = vector.getInt("toolCallCount"),
                    isError = vector.getBoolean("isError"),
                    terminal = terminal,
                ),
            )
        }
    }

    private fun assertSafety(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val authenticated = if (vector.has("authenticated")) vector.getBoolean("authenticated") else true
        val bindingMatches = if (vector.has("bindingMatches")) vector.getBoolean("bindingMatches") else true
        assertEquals(
            expected.getString("decision"),
            MobileComputerUseSafetyPolicy.decision(
                kind = vector.getString("decisionKind"),
                authenticated = authenticated,
                grantExpired = vector.optBoolean("grantExpired"),
                bindingMatches = bindingMatches,
                replayed = vector.optBoolean("replayed"),
                tampered = vector.optBoolean("tampered"),
            ).wire,
        )
        assertEquals(
            expected.getString("reason"),
            MobileComputerUseSafetyPolicy.reason(
                kind = vector.getString("decisionKind"),
                authenticated = authenticated,
                grantExpired = vector.optBoolean("grantExpired"),
                bindingMatches = bindingMatches,
                replayed = vector.optBoolean("replayed"),
                tampered = vector.optBoolean("tampered"),
            ),
        )
    }

    private fun hermesVector(id: String): JSONObject {
        val fixture = JSONObject(locate("docs/mobile-parity/fixtures/product/hermes-mercury-computer-use-vectors.json").readText())
        val vectors = fixture.getJSONArray("vectors")
        for (index in 0 until vectors.length()) {
            val candidate = vectors.getJSONObject(index)
            if (candidate.getString("id") == id) return candidate
        }
        error("missing vector $id")
    }

    private fun locate(relative: String): File {
        val cwd = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val anchors = listOf(File(cwd), File(cwd, "../.."), File(cwd, ".."))
        for (anchor in anchors) {
            var dir: File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("could not locate $relative")
    }

    private fun expectedStringList(array: JSONArray): List<String> = (0 until array.length()).map { array.getString(it) }
}
