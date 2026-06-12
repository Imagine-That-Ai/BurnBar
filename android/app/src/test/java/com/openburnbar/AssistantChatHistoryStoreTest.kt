
package com.openburnbar

import android.content.ContextWrapper
import com.openburnbar.data.assistants.AssistantChatCloudMirror
import com.openburnbar.data.assistants.AssistantChatFileLocalStore
import com.openburnbar.data.assistants.AssistantChatHistorySnapshot
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatLocalStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantChatHistoryStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

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
        local.partitions["local"] =
            AssistantChatHistorySnapshot(
                threads = listOf(makeThread("dead", "pi", "Bye")),
                tombstones = mapOf("dead" to System.currentTimeMillis()),
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

        assertTrue(
            "local-only thread must backfill once online",
            cloud.upserts.any { it.id == "local-only" },
        )
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
    fun `file local store saves partitioned thread files and reloads from disk digests`() {
        val filesDir = tempFolder.newFolder("assistant-files")
        val local = AssistantChatFileLocalStore(FilesDirContext(filesDir))
        val unsafeThread = makeThread("thread/unsafe?", "pi", "Unsafe")
        val safeThread = makeThread("thread-safe", "hermes", "Safe")
        val snapshot =
            AssistantChatHistorySnapshot(
                threads = listOf(unsafeThread, safeThread),
                tombstones = mapOf("gone" to 123L),
            )
        local.setActivePartition("user/with/slashes")

        local.save(snapshot)
        local.save(snapshot)

        val partitionDir = File(filesDir, "assistant-chat-history/partition-user-with-slashes")
        val unsafeThreadFile =
            File(partitionDir, "thread-${AssistantChatFileLocalStore.sanitizeThreadFileComponent(unsafeThread.id)}.json")
        val safeThreadFile =
            File(partitionDir, "thread-${AssistantChatFileLocalStore.sanitizeThreadFileComponent(safeThread.id)}.json")
        assertTrue(File(partitionDir, "index.json").isFile)
        assertTrue(unsafeThreadFile.isFile)
        assertTrue(safeThreadFile.isFile)

        val reloaded = AssistantChatFileLocalStore(FilesDirContext(filesDir))
        reloaded.setActivePartition("user/with/slashes")
        reloaded.save(snapshot.copy(threads = listOf(unsafeThread.copy(title = "Updated"))))

        assertFalse("stale thread body should be deleted", safeThreadFile.exists())
        val loaded = reloaded.load()
        assertEquals(listOf("Updated"), loaded.threads.map { it.title })
        assertEquals(123L, loaded.tombstones["gone"])
    }

    @Test
    fun `file local store migrates legacy envelope into indexed thread files`() {
        val filesDir = tempFolder.newFolder("legacy-envelope")
        val root = File(filesDir, "assistant-chat-history").apply { mkdirs() }
        val legacy = File(root, "assistant-chat-history-local.json")
        val thread = makeThread("legacy-thread", "pi", "Legacy")
        legacy.writeText(diskJson.encodeToString(AssistantChatHistorySnapshot(threads = listOf(thread), tombstones = mapOf("old" to 456L))))

        val loaded = AssistantChatFileLocalStore(FilesDirContext(filesDir)).load()

        assertEquals(listOf("legacy-thread"), loaded.threads.map { it.id })
        assertEquals(456L, loaded.tombstones["old"])
        assertFalse("legacy file should be consumed after migration", legacy.exists())
        assertTrue(File(root, "partition-local/index.json").isFile)
    }

    @Test
    fun `file local store migrates legacy bare thread array`() {
        val filesDir = tempFolder.newFolder("legacy-array")
        val root = File(filesDir, "assistant-chat-history").apply { mkdirs() }
        val legacy = File(root, "assistant-chat-history-local.json")
        legacy.writeText(diskJson.encodeToString(listOf(makeThread("legacy-array-thread", "hermes", "Legacy Array"))))

        val loaded = AssistantChatFileLocalStore(FilesDirContext(filesDir)).load()

        assertEquals(listOf("legacy-array-thread"), loaded.threads.map { it.id })
        assertFalse(legacy.exists())
    }

    @Test
    fun `file local store drops stale legacy file when index exists`() {
        val filesDir = tempFolder.newFolder("stale-legacy")
        val local = AssistantChatFileLocalStore(FilesDirContext(filesDir))
        local.save(AssistantChatHistorySnapshot(threads = listOf(makeThread("indexed", "pi", "Indexed"))))
        val legacy = File(filesDir, "assistant-chat-history/assistant-chat-history-local.json").apply { writeText("stale") }

        val loaded = AssistantChatFileLocalStore(FilesDirContext(filesDir)).load()

        assertEquals(listOf("indexed"), loaded.threads.map { it.id })
        assertFalse("stale legacy file should be deleted once index exists", legacy.exists())
    }

    @Test
    fun `file local store recovers safe thread files when index is missing`() {
        val filesDir = tempFolder.newFolder("scan-index")
        val local = AssistantChatFileLocalStore(FilesDirContext(filesDir))
        local.save(AssistantChatHistorySnapshot(threads = listOf(makeThread("safe-thread", "pi", "Safe"))))
        val index = File(filesDir, "assistant-chat-history/partition-local/index.json")
        assertTrue(index.delete())

        val loaded = AssistantChatFileLocalStore(FilesDirContext(filesDir)).load()

        assertEquals(listOf("safe-thread"), loaded.threads.map { it.id })
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

    private val diskJson =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

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
            messages =
            listOf(
                AssistantChatMessage(
                    id = "$id-m0",
                    role = "user",
                    text = "Hello $title",
                    timestampMillis = now,
                ),
            ),
        )
    }
}

private class FilesDirContext(private val files: File) : ContextWrapper(null) {
    override fun getFilesDir(): File = files
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
