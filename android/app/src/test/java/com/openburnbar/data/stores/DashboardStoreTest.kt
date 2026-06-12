
package com.openburnbar.data.stores

import com.openburnbar.MainDispatcherRule
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import java.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

/**
 * Listener-lifecycle and rebuild-throttle tests for [DashboardStore],
 * complementing the load/refresh staleness suite in
 * `com.openburnbar.DashboardStoreTest`: listener failures must surface as
 * state (never as an unhandled main-thread crash — the PERMISSION_DENIED
 * regression), stopListening must actually detach, and the server-side
 * rollup rebuild must stay throttled to one attempt per minute.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DashboardStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `startListening publishes streamed rollups`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val live = MutableSharedFlow<UsageRollups>()
        every { mockRepo.listenToRollups() } returns live

        val store = DashboardStore(mockRepo)
        store.startListening()
        advanceUntilIdle()

        val first = UsageRollups(today = 1.0, computedAt = Instant.now().toString())
        live.emit(first)
        advanceUntilIdle()
        assertEquals(first, store.rollups.value)

        store.stopListening()
    }

    @Test
    fun `listener errors land in error state instead of crashing the main dispatcher`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        every { mockRepo.listenToRollups() } returns flow { throw IllegalStateException("PERMISSION_DENIED") }

        val store = DashboardStore(mockRepo)
        store.startListening()
        advanceUntilIdle()

        assertEquals("PERMISSION_DENIED", store.error.value)
        store.stopListening()
    }

    @Test
    fun `listener errors without a message fall back to the exception type name`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        every { mockRepo.listenToRollups() } returns flow { throw IllegalStateException() }

        val store = DashboardStore(mockRepo)
        store.startListening()
        advanceUntilIdle()

        assertEquals("IllegalStateException", store.error.value)
        store.stopListening()
    }

    @Test
    fun `stopListening detaches so later emissions are ignored`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val live = MutableSharedFlow<UsageRollups>()
        every { mockRepo.listenToRollups() } returns live

        val store = DashboardStore(mockRepo)
        store.startListening()
        advanceUntilIdle()
        store.stopListening()
        advanceUntilIdle()

        live.emit(UsageRollups(today = 99.0, computedAt = Instant.now().toString()))
        advanceUntilIdle()
        assertNull(store.rollups.value)
    }

    @Test
    fun `empty rollups trigger at most one server rebuild per minute`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchRollups() } returns UsageRollups()
        coEvery { mockRepo.rebuildUsageRollups() } just Runs

        val store = DashboardStore(mockRepo)
        store.load()
        advanceUntilIdle()
        // A second load inside the 60s window must NOT fire another callable.
        store.refresh()
        advanceUntilIdle()

        coVerify(exactly = 1) { mockRepo.rebuildUsageRollups() }
        assertNull(store.error.value)
    }

    @Test
    fun `malformed computedAt counts as fresh and never fires a rebuild`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val garbled = UsageRollups(today = 3.0, computedAt = "not-an-instant")
        coEvery { mockRepo.fetchRollups() } returns garbled

        val store = DashboardStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals(garbled, store.rollups.value)
        coVerify(exactly = 0) { mockRepo.rebuildUsageRollups(any()) }
    }

    @Test
    fun `a failed newest usage probe counts as fresh`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val rollups = UsageRollups(today = 5.0, computedAt = Instant.now().minusSeconds(3_600).toString())
        coEvery { mockRepo.fetchRollups() } returns rollups
        coEvery { mockRepo.fetchNewestUsageEndTime() } throws IllegalStateException("offline")

        val store = DashboardStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals(rollups, store.rollups.value)
        coVerify(exactly = 0) { mockRepo.rebuildUsageRollups(any()) }
    }
}
