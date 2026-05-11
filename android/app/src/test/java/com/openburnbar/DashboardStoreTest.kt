package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
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


}
