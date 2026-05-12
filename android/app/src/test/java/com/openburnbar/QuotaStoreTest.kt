package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.stores.QuotaStore
import io.mockk.*
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class QuotaStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `load fetches snapshots and accounts`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val snapshots = listOf(
            ProviderQuotaSnapshot(provider = "openai")
        )
        coEvery { mockRepo.fetchQuotaSnapshots() } returns snapshots
        coEvery { mockRepo.fetchProviderAccounts() } returns emptyList()
        every { mockRepo.listenToQuotaSnapshots() } returns flowOf(snapshots)

        val store = QuotaStore(mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals(1, store.snapshots.value.size)
        assertEquals("openai", store.snapshots.value.first().provider)
        assertEquals(0.0, store.snapshots.value.first().percentageRemaining, 0.01)
        assertNull(store.error.value)

        store.stopListening()
    }

    @Test
    fun `refresh updates snapshots`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val initial = listOf(ProviderQuotaSnapshot(provider = "openai"))
        val updated = listOf(ProviderQuotaSnapshot(provider = "openai"))
        coEvery { mockRepo.fetchQuotaSnapshots() } returnsMany listOf(initial, updated)
        coEvery { mockRepo.fetchProviderAccounts() } returns emptyList()
        every { mockRepo.listenToQuotaSnapshots() } returns flowOf(initial)

        val store = QuotaStore(mockRepo)
        store.load()
        advanceUntilIdle()
        assertEquals(0.0, store.snapshots.value.first().percentageRemaining, 0.01)

        store.refresh()
        advanceUntilIdle()
        assertEquals(0.0, store.snapshots.value.first().percentageRemaining, 0.01)
    }
}
