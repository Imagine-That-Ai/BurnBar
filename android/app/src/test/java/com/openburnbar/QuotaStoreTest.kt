
package com.openburnbar

import android.app.Application
import com.google.firebase.FirebaseException
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.stores.QuotaStore
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class QuotaStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `default AndroidViewModel factory can construct quota store`() {
        val constructor = QuotaStore::class.java.getConstructor(Application::class.java)

        assertNotNull(constructor)
    }

    @Test
    fun `load fetches snapshots and accounts`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val snapshots =
            listOf(
                ProviderQuotaSnapshot(provider = "openai"),
            )
        coEvery { mockRepo.fetchQuotaSnapshots() } returns snapshots
        coEvery { mockRepo.fetchProviderAccounts() } returns emptyList()
        every { mockRepo.listenToQuotaSnapshots() } returns flowOf(snapshots)

        val store = QuotaStore(mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals(1, store.snapshots.value.size)
        assertEquals("openai", store.snapshots.value.first().provider)
        assertEquals(100.0, store.snapshots.value.first().percentageRemaining, 0.01)
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
        assertEquals(100.0, store.snapshots.value.first().percentageRemaining, 0.01)

        store.refresh()
        advanceUntilIdle()
        assertEquals(100.0, store.snapshots.value.first().percentageRemaining, 0.01)
    }

    @Test
    fun `load surfaces Firestore permission errors instead of crashing main dispatcher`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchQuotaSnapshots() } throws firestorePermissionDenied()

        val store = QuotaStore(mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals("Missing or insufficient permissions.", store.error.value)
        assertEquals(emptyList<ProviderQuotaSnapshot>(), store.snapshots.value)
    }

    @Test
    fun `refresh surfaces Firestore permission errors instead of crashing main dispatcher`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchQuotaSnapshots() } throws firestorePermissionDenied()

        val store = QuotaStore(mockRepo)
        store.refresh()
        advanceUntilIdle()

        assertEquals("Missing or insufficient permissions.", store.error.value)
        assertEquals(emptyList<ProviderQuotaSnapshot>(), store.snapshots.value)
    }

    private fun firestorePermissionDenied(): FirebaseException = mockk {
        every { message } returns "Missing or insufficient permissions."
    }
}
