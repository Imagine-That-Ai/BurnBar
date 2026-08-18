
package com.openburnbar

import com.google.firebase.FirebaseException
import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.StreamsSegment
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ActivityStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `loadInitial fetches first page`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val usages = listOf(TokenUsage(id = "1", provider = "openai", model = "gpt-4", cost = 0.50, timestamp = 1700000000000L))
        coEvery { mockRepo.fetchUsagePage(any(), any(), any(), any(), any(), any(), any()) } returns (usages to mockk(relaxed = true))
        every { mockRepo.listenToUsagePage() } returns flowOf(usages)

        val store = ActivityStore(mockRepo)
        store.loadInitial()
        advanceUntilIdle()

        assertEquals(1, store.usages.value.size)
        assertEquals("gpt-4", store.usages.value.first().model)
        assertTrue(store.hasMore.value)

        store.stopListening()
    }

    @Test
    fun `setSegment to projects loads projects`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val projects = listOf(ProjectSummary(id = "p1", name = "MyApp", totalCost = 12.50))
        coEvery { mockRepo.fetchUsagePage(any(), any(), any(), any(), any(), any(), any()) } returns (emptyList<TokenUsage>() to null)
        coEvery { mockRepo.fetchProjects() } returns projects
        every { mockRepo.listenToUsagePage() } returns flowOf(emptyList())

        val store = ActivityStore(mockRepo)
        store.loadInitial()
        advanceUntilIdle()

        store.setSegment(StreamsSegment.PROJECTS)
        advanceUntilIdle()

        assertEquals(StreamsSegment.PROJECTS, store.selectedSegment.value)
        assertEquals(1, store.projects.value.size)
        assertEquals("MyApp", store.projects.value.first().name)

        store.stopListening()
    }

    @Test
    fun `loadNext appends page`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val page1 = listOf(TokenUsage(id = "1", provider = "openai"))
        val page2 = listOf(TokenUsage(id = "2", provider = "claude-code"))
        val pageCursor = mockk<DocumentSnapshot>(relaxed = true)
        coEvery { mockRepo.fetchUsagePage(any(), null, any(), any(), any(), any(), any()) } returns (page1 to pageCursor)
        coEvery { mockRepo.fetchUsagePage(any(), pageCursor, any(), any(), any(), any(), any()) } returns (page2 to null)
        every { mockRepo.listenToUsagePage() } returns flowOf(page1 + page2)

        val store = ActivityStore(mockRepo)
        store.loadInitial()
        advanceUntilIdle()
        assertEquals(1, store.usages.value.size)
        assertTrue(store.hasMore.value)

        store.loadNext()
        advanceUntilIdle()
        assertEquals(2, store.usages.value.size)
        assertFalse(store.hasMore.value)

        store.stopListening()
    }

    @Test
    fun `successful load clears a previous error`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val usages = listOf(TokenUsage(id = "1", provider = "openai"))
        coEvery { mockRepo.fetchUsagePage(any(), any(), any(), any(), any(), any(), any()) } throws firestoreUnavailable() andThen (usages to null)
        every { mockRepo.listenToUsagePage() } returns flowOf(usages)

        val store = ActivityStore(mockRepo)
        store.loadInitial()
        advanceUntilIdle()
        assertEquals("unavailable", store.error.value)
        assertTrue(store.usages.value.isEmpty())

        store.loadInitial()
        advanceUntilIdle()
        assertEquals(null, store.error.value)
        assertEquals(1, store.usages.value.size)
        store.stopListening()
    }

    @Test
    fun `search failure is not an empty result`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchUsagePage(any(), any(), any(), any(), any(), any(), any()) } returns (emptyList<TokenUsage>() to null)
        every { mockRepo.listenToUsagePage() } returns flowOf(emptyList())

        val store = ActivityStore(
            mockRepo,
            cloudSearchFactory = {
                mockk {
                    coEvery { search(any()) } throws IllegalStateException("index unavailable")
                }
            },
        )
        store.updateSearch("codex")
        advanceUntilIdle()
        assertTrue(store.searchFailed.value)
        assertEquals("index unavailable", store.error.value)
        store.stopListening()
    }

    private fun firestoreUnavailable(): FirebaseException = mockk {
        every { message } returns "unavailable"
    }
}
