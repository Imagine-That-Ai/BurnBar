package com.openburnbar.data.projects

import android.text.TextUtils
import com.google.firebase.FirebaseException
import com.openburnbar.MainDispatcherRule
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProjectSummary
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * Parity `ProjectsStore` (Hermes Square §6.3) load-path tests: a signed-out
 * session must surface the friendly "Sign in required" message as a normal
 * error state instead of crashing the brand zone / Project Memory Wiki load.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ProjectsStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    /**
     * Builds a real [FirebaseException]: its constructor validates the
     * message through `android.text.TextUtils`, which is unmocked on the
     * pure JVM, so just that static call is bridged for the construction.
     */
    private fun firestoreDenial(message: String): FirebaseException {
        mockkStatic(TextUtils::class)
        try {
            every { TextUtils.isEmpty(any()) } answers { firstArg<CharSequence?>().isNullOrEmpty() }
            return FirebaseException(message)
        } finally {
            unmockkStatic(TextUtils::class)
        }
    }

    @Test
    fun `load surfaces signed-out state as an error instead of crashing`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchProjects() } throws FirestoreRepository.NotSignedInException()

        val store = ProjectsStore(repo = mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals("Sign in required to load your dashboard.", store.error.value)
        assertTrue(store.summaries.value.isEmpty())
        assertFalse(store.isLoading.value)
    }

    @Test
    fun `load surfaces Firebase errors and clears loading`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        coEvery { mockRepo.fetchProjects() } throws firestoreDenial("PERMISSION_DENIED: request denied")

        val store = ProjectsStore(repo = mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals("PERMISSION_DENIED: request denied", store.error.value)
        assertFalse(store.isLoading.value)
    }

    @Test
    fun `load publishes summaries and resets error on success`() = runTest {
        val mockRepo = mockk<FirestoreRepository>()
        val summaries = listOf(ProjectSummary(id = "proj-1"))
        coEvery { mockRepo.fetchProjects() } returns summaries

        val store = ProjectsStore(repo = mockRepo)
        store.load()
        advanceUntilIdle()

        assertEquals(summaries, store.summaries.value)
        assertNull(store.error.value)
        assertFalse(store.isLoading.value)
    }
}
