package com.openburnbar.data.square

import com.openburnbar.data.assistants.AssistantChatHistorySnapshot
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatLocalStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.hermes.AssistantRuntimeID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ThreadInboxRefreshPartsTest {
    @Test
    fun `Junie runtime aliases from history are kept as CLI mirror items`() = runTest {
        val history =
            AssistantChatHistoryStore(
                local = InMemoryAssistantChatLocalStore(),
                cloud = null,
                scope = CoroutineScope(StandardTestDispatcher(testScheduler)),
            )
        history.upsert(makeThread("junie-agent-thread", "junie-agent"))
        history.upsert(makeThread("jetbrains-junie-thread", "jetbrains-junie"))

        val parts = buildThreadInboxRefreshParts(parsed = emptyList(), history = history, missionHost = null)

        assertEquals(
            listOf("cli_mirror:jetbrains-junie-thread", "cli_mirror:junie-agent-thread"),
            parts.items.map { it.id }.sorted(),
        )
        assertTrue(parts.items.all { it.source == ThreadInboxItem.Source.CLI_MIRROR })
        assertTrue(parts.items.all { it.agentURI == AgentIdentity.builtInURI(AssistantRuntimeID.JUNIE) })
    }

    private fun makeThread(id: String, runtime: String): AssistantChatThread {
        val now = 1_783_036_800_000L
        return AssistantChatThread(
            id = id,
            runtime = runtime,
            title = id,
            preview = "Preview for $id",
            createdAtMillis = now,
            updatedAtMillis = now,
            messages =
            listOf(
                AssistantChatMessage(
                    id = "$id-message",
                    role = "user",
                    text = "Hello Junie",
                    timestampMillis = now,
                ),
            ),
        )
    }
}

private class InMemoryAssistantChatLocalStore : AssistantChatLocalStore {
    private var snapshot: AssistantChatHistorySnapshot = AssistantChatHistorySnapshot()

    override fun setActivePartition(key: String) {
        // Single-partition test store.
    }

    override fun load(): AssistantChatHistorySnapshot = snapshot

    override fun save(snapshot: AssistantChatHistorySnapshot) {
        this.snapshot = snapshot
    }
}
