@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.DashboardStore
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import java.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DashboardStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `load fetches rollups and starts listening`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val rollups = UsageRollups(today = 1.0, computedAt = Instant.now().toString())
        coEvery { mockRepo.fetchRollups() } returns rollups
        coEvery { mockRepo.fetchNewestUsageEndTime() } returns null
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
    fun `refresh rebuilds rollups older than the newest usage event`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val computedAt = Instant.now().minusSeconds(16 * 60)
        val stale = UsageRollups(today = 1.0, computedAt = computedAt.toString())
        val rebuilt = UsageRollups(today = 14.0, computedAt = Instant.now().toString())
        coEvery { mockRepo.fetchRollups() } returnsMany listOf(stale, rebuilt)
        coEvery { mockRepo.fetchNewestUsageEndTime() } returns computedAt.plusSeconds(60)
        coEvery { mockRepo.rebuildUsageRollups(any()) } just Runs

        val store = DashboardStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals(rebuilt, store.rollups.value)
        assertNull(store.error.value)
        coVerify(exactly = 1) { mockRepo.rebuildUsageRollups(any()) }
    }

    // Regression (crosscut-001): wall-clock age alone is NOT staleness. Old
    // rollups with no newer usage are legitimately old (idle user) and must
    // not fire the rebuildUsageRollups callable on every app open.
    @Test
    fun `refresh keeps old rollups without newer usage and skips the server rebuild`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val computedAt = Instant.now().minusSeconds(4 * 60 * 60)
        val idle = UsageRollups(today = 1.0, computedAt = computedAt.toString())
        coEvery { mockRepo.fetchRollups() } returns idle
        coEvery { mockRepo.fetchNewestUsageEndTime() } returns computedAt.minusSeconds(60 * 60)

        val store = DashboardStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals(idle, store.rollups.value)
        assertNull(store.error.value)
        coVerify(exactly = 0) { mockRepo.rebuildUsageRollups(any()) }
    }

    @Test
    fun `forceRebuild requests the forced server-side counter rebuild`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val rebuilt = UsageRollups(today = 14.0, computedAt = Instant.now().toString())
        coEvery { mockRepo.rebuildUsageRollups(force = true) } just Runs
        coEvery { mockRepo.fetchRollups() } returns rebuilt

        val store = DashboardStore(mockRepo)
        store.forceRebuild()
        advanceUntilIdle()

        assertEquals(rebuilt, store.rollups.value)
        coVerify(exactly = 1) { mockRepo.rebuildUsageRollups(force = true) }
    }
}
