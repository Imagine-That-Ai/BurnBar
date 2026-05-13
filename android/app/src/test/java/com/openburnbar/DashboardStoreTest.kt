package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.DashboardStore
import io.mockk.*
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.time.Instant

class DashboardStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `load fetches rollups and starts listening`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val rollups = UsageRollups(today = 1.0, computedAt = Instant.now().toString())
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
    fun `load rebuilds empty rollups before publishing refreshed value`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val empty = UsageRollups()
        val rebuilt = UsageRollups(today = 12.0, computedAt = Instant.now().toString())
        coEvery { mockRepo.fetchRollups() } returnsMany listOf(empty, rebuilt)
        coEvery { mockRepo.rebuildUsageRollups() } just Runs

        val store = DashboardStore(mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals(rebuilt, store.rollups.value)
        assertNull(store.error.value)
        coVerify(exactly = 1) { mockRepo.rebuildUsageRollups() }
    }

    @Test
    fun `refresh rebuilds stale rollups`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val stale = UsageRollups(
            today = 1.0,
            computedAt = Instant.now().minusSeconds(16 * 60).toString()
        )
        val rebuilt = UsageRollups(today = 14.0, computedAt = Instant.now().toString())
        coEvery { mockRepo.fetchRollups() } returnsMany listOf(stale, rebuilt)
        coEvery { mockRepo.rebuildUsageRollups() } just Runs

        val store = DashboardStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals(rebuilt, store.rollups.value)
        assertNull(store.error.value)
        coVerify(exactly = 1) { mockRepo.rebuildUsageRollups() }
    }

}
