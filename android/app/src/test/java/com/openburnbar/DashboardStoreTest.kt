package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.firebase.UsageRollups
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.TimelineScope
import com.openburnbar.data.stores.DashboardStore
import io.mockk.*
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class DashboardStoreTest {

    @Test
    fun `load fetches rollups and starts listening`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val rollups = UsageRollups()
        coEvery { mockRepo.fetchRollups() } returns rollups
        every { mockRepo.listenToRollups() } returns flowOf(rollups)

        val store = DashboardStore(mockRepo)
        assertEquals(false, store.isLoading.value)

        store.load()
        advanceUntilIdle()

        assertEquals(rollups, store.rollups.value)
        assertEquals(false, store.isLoading.value)
        assertNull(store.error.value)

        store.stopListening()
    }

    @Test
    fun `setDisplayMode updates state`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchRollups() } returns UsageRollups()
        every { mockRepo.listenToRollups() } returns flowOf(UsageRollups())

        val store = DashboardStore(mockRepo)
        assertEquals(UsageDisplayMode.CURRENCY, store.displayMode.value)

        store.setDisplayMode(UsageDisplayMode.TOKENS)
        assertEquals(UsageDisplayMode.TOKENS, store.displayMode.value)
    }

    @Test
    fun `setScope updates selected scope`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchRollups() } returns UsageRollups()
        every { mockRepo.listenToRollups() } returns flowOf(UsageRollups())

        val store = DashboardStore(mockRepo)
        assertEquals(TimelineScope.DAY, store.selectedScope.value)

        store.setScope(TimelineScope.WEEK)
        assertEquals(TimelineScope.WEEK, store.selectedScope.value)
    }
}
