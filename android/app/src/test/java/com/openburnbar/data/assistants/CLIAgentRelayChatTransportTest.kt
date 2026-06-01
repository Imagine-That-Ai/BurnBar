@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.assistants

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelCatalogResponse
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CLIAgentRelayChatTransportTest {
    @Test
    fun `stream sends ios parity cli agent relay request and decodes events`() = runTest {
        val fake =
            FakePayloadStreamer(
                rawEvents =
                listOf(
                    """
                            {
                              "kind": "completed",
                              "text": "Mac Codex answered.",
                              "modelID": "gpt-test",
                              "transcriptPieces": [
                                {"id": "p1", "kind": "text", "value": "Mac Codex answered."},
                                {"id": "p2", "kind": "toolUse", "value": "Read", "detail": "AgentLens/App.swift"}
                              ]
                            }
                    """.trimIndent(),
                ),
            )
        val transport = CLIAgentRelayChatTransport(fake)
        val events = mutableListOf<CLIAgentRelayChatEvent>()

        transport.stream(
            request =
            CLIAgentRelayChatStreamRequest(
                runtime = AssistantRuntimeID.CODEX,
                threadID = "android-codex-thread",
                prompt = "  Hello from Android  ",
                title = "  Android thread  ",
                modelID = "  gpt-test  ",
                parentSessionID = "parent-session",
                resumeAction = "continue",
                presentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
            ),
        ) { event ->
            events += event
        }

        val body = JSONObject(fake.bodyString)
        assertEquals("android-codex-thread", fake.sessionID)
        assertEquals("codex", body.getString("runtime"))
        assertEquals("Hello from Android", body.getString("prompt"))
        assertEquals("android-codex-thread", body.getString("clientThreadID"))
        assertEquals("gpt-test", body.getString("modelID"))
        assertEquals("Android thread", body.getString("title"))
        assertEquals("parent-session", body.getString("parentSessionID"))
        assertEquals("continue", body.getString("resumeAction"))
        assertEquals("native_chat", body.getString("presentationMode"))

        assertEquals(1, events.size)
        assertEquals(CLIAgentRelayChatEventKind.COMPLETED, events.first().kind)
        assertEquals("Mac Codex answered.", events.first().text)
        assertEquals("gpt-test", events.first().modelID)
        assertEquals(CLIAgentRelayTranscriptPieceKind.TOOL_USE, events.first().transcriptPieces[1].kind)
        assertEquals("AgentLens/App.swift", events.first().transcriptPieces[1].detail)
    }

    @Test
    fun `request defaults to native chat wire value`() {
        val body =
            JSONObject(
                String(
                    CLIAgentRelayChatRequest(
                        runtime = "claude",
                        prompt = "hello",
                        clientThreadID = "thread-1",
                    ).toJsonByteArray(),
                    Charsets.UTF_8,
                ),
            )

        assertEquals("native_chat", body.getString("presentationMode"))
    }

    @Test
    fun `stream propagates relay event decode errors`() = runTest {
        val fake = FakePayloadStreamer(rawEvents = listOf("""{"kind":"bogus"}"""))
        val transport = CLIAgentRelayChatTransport(fake)

        val error =
            runCatching {
                transport.stream(
                    request =
                    CLIAgentRelayChatStreamRequest(
                        runtime = AssistantRuntimeID.CLAUDE,
                        threadID = "thread-1",
                        prompt = "hello",
                        title = "Thread",
                        presentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
                    ),
                ) {}
            }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
    }
}

private class FakePayloadStreamer(
    private val rawEvents: List<String>,
) : CLIAgentRelayChatPayloadStreamer {
    var bodyString: String = ""
        private set
    var sessionID: String = ""
        private set

    override suspend fun fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse = CliRuntimeModelCatalogResponse(
        runtime = runtime.token,
        machineName = "Test Mac",
        generatedAtEpochMillis = 1L,
        options = emptyList(),
    )

    override suspend fun streamCLIAgentChatPayload(body: ByteArray, sessionID: String, onRawEvent: suspend (String) -> Unit) {
        bodyString = String(body, Charsets.UTF_8)
        this.sessionID = sessionID
        rawEvents.forEach { onRawEvent(it) }
    }

    override suspend fun sendCLIAgentSessionActionPayload(body: ByteArray, sessionID: String): String {
        bodyString = String(body, Charsets.UTF_8)
        this.sessionID = sessionID
        return """{"status":"error","argv":[]}"""
    }
}
