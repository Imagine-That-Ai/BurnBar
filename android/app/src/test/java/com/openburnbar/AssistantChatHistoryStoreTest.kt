package com.openburnbar

import com.openburnbar.data.assistants.AssistantChatCloudMirror
import com.openburnbar.data.assistants.AssistantChatHistorySnapshot
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatLocalStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantChatHistoryStoreTest {

    @Test
    fun `upsert persists to local store`() = runTest {
        val local = InMemoryLocalStore()
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))

        store.upsert(makeThread("t1", "pi", "Hello"))

        assertEquals(1, store.threadsFor("pi").size)
        assertEquals("t1", local.snapshot.threads.first().id)
    }

    @Test
    fun `threads are filtered by runtime`() = runTest {
        val local = InMemoryLocalStore()
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))

        store.upsert(makeThread("pi-1", "pi", "Pi"))
        store.upsert(makeThread("h-1", "hermes", "Hermes"))

        assertEquals(listOf("pi-1"), store.threadsFor("pi").map { it.id })
        assertEquals(listOf("h-1"), store.threadsFor("hermes").map { it.id })
    }

    @Test
    fun `tombstoned thread is hidden after restore`() = runTest {
        val local = InMemoryLocalStore()
        local.partitions["local"] = AssistantChatHistorySnapshot(
            threads = listOf(makeThread("dead", "pi", "Bye")),
            tombstones = mapOf("dead" to System.currentTimeMillis())
        )
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))
        store.loadFromDiskIfNeeded()
        assertTrue(store.threads.value.isEmpty())
    }

    @Test
    fun `delete records tombstone and removes thread`() = runTest {
        val local = InMemoryLocalStore()
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))
        store.upsert(makeThread("t1", "pi", "Bye"))

        store.delete("t1")

        assertTrue(store.threads.value.isEmpty())
        assertNotNull("tombstone must be written for offline-safe sync", local.snapshot.tombstones["t1"])
    }

    @Test
    fun `upsert after delete refuses resurrection`() = runTest {
        val local = InMemoryLocalStore()
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))
        store.upsert(makeThread("t1", "pi", "First"))
        store.delete("t1")

        store.upsert(makeThread("t1", "pi", "Resurrection"))

        assertTrue(store.threads.value.isEmpty())
    }

    @Test
    fun `switchPartition isolates users`() = runTest {
        val local = InMemoryLocalStore()
        val store = AssistantChatHistoryStore(local, cloud = null, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))

        store.switchPartition("userA")
        store.upsert(makeThread("A1", "pi", "Alice"))
        assertEquals(listOf("A1"), store.threads.value.map { it.id })

        store.switchPartition("userB")
        assertTrue("Bob must not see Alice's threads", store.threads.value.isEmpty())

        store.switchPartition("userA")
        assertEquals(listOf("A1"), store.threads.value.map { it.id })
    }

    @Test
    fun `refreshFromCloud pushes local-only threads`() = runTest {
        val local = InMemoryLocalStore()
        val cloud = MockCloud()
        val store = AssistantChatHistoryStore(local, cloud, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))
        store.upsert(makeThread("local-only", "pi", "Created offline"))
        assertTrue("cloud is offline at upsert time", cloud.upserts.isEmpty())

        cloud.isAvailableValue = true
        store.refreshFromCloud()
        advanceUntilIdle()

        assertTrue("local-only thread must backfill once online",
            cloud.upserts.any { it.id == "local-only" })
    }

    @Test
    fun `refreshFromCloud does not resurrect tombstoned thread`() = runTest {
        val local = InMemoryLocalStore()
        val cloud = MockCloud()
        val thread = makeThread("dead", "pi", "Should stay dead")
        cloud.remote = mutableListOf(thread)
        cloud.isAvailableValue = true

        val store = AssistantChatHistoryStore(local, cloud, scope = CoroutineScope(StandardTestDispatcher(testScheduler)))
        store.upsert(thread)
        store.delete("dead")

        store.refreshFromCloud()
        advanceUntilIdle()

        assertFalse(store.threads.value.any { it.id == "dead" })
    }

    @Test
    fun `sanitizePartitionKey strips path separators`() {
        assertEquals("user-with-slashes", AssistantChatHistoryStore.sanitizePartitionKey("user/with/slashes"))
        assertEquals("local", AssistantChatHistoryStore.sanitizePartitionKey(""))
        assertEquals("escape", AssistantChatHistoryStore.sanitizePartitionKey("../escape"))
    }

    @Test
    fun `merge keeps newest updatedAt`() {
        val older = 100L
        val newer = 200L
        val localThread = makeThread("shared", "pi", "Local copy").copy(updatedAtMillis = newer)
        val remoteThread = makeThread("shared", "pi", "Remote copy").copy(updatedAtMillis = older)

        val merged = AssistantChatHistoryStore.merge(listOf(localThread), listOf(remoteThread))

        assertEquals(1, merged.size)
        assertEquals("Local copy", merged.first().title)
    }

    // MARK: - helpers

    private fun makeThread(id: String, runtime: String, title: String): AssistantChatThread {
        val now = System.currentTimeMillis()
        return AssistantChatThread(
            id = id,
            runtime = runtime,
            title = title,
            preview = "Preview for $title",
            modelName = null,
            createdAtMillis = now,
            updatedAtMillis = now,
            messages = listOf(
                AssistantChatMessage(
                    id = "$id-m0",
                    role = "user",
                    text = "Hello $title",
                    timestampMillis = now
                )
            )
        )
    }
}

private class InMemoryLocalStore : AssistantChatLocalStore {
    val partitions: MutableMap<String, AssistantChatHistorySnapshot> = mutableMapOf()
    private var activePartition: String = "local"

    val snapshot: AssistantChatHistorySnapshot
        get() = partitions[activePartition] ?: AssistantChatHistorySnapshot()

    override fun setActivePartition(key: String) {
        activePartition = key
    }

    override fun load(): AssistantChatHistorySnapshot = snapshot

    override fun save(snapshot: AssistantChatHistorySnapshot) {
        partitions[activePartition] = snapshot
    }
}

private class MockCloud : AssistantChatCloudMirror {
    var isAvailableValue: Boolean = false
    var currentUserIDValue: String? = "test-uid"
    var remote: MutableList<AssistantChatThread> = mutableListOf()
    val upserts: MutableList<AssistantChatThread> = mutableListOf()
    val deletes: MutableList<String> = mutableListOf()

    override val isAvailable: Boolean get() = isAvailableValue
    override val currentUserID: String? get() = currentUserIDValue

    override suspend fun upsert(thread: AssistantChatThread) {
        upserts.add(thread)
        val idx = remote.indexOfFirst { it.id == thread.id }
        if (idx >= 0) remote[idx] = thread else remote.add(thread)
    }

    override suspend fun delete(threadID: String) {
        deletes.add(threadID)
        remote.removeAll { it.id == threadID }
    }

    override suspend fun fetchAll(): List<AssistantChatThread> = remote.toList()
}
