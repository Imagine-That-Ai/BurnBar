package com.openburnbar.data.square

import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.QuerySnapshot
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestResult
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit coverage for [ThreadInboxStore.refreshFromCloud] resilience: transient
 * Firebase failures (App Check refresh windows) must stay bounded, retry with
 * doubling backoff, preserve coroutine cancellation, and never leave the store
 * stuck in a loading state.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ThreadInboxStoreRefreshTest {
    @Before
    fun stubVaultKeyAccess() {
        mockkObject(AndroidCloudVaultKeyAccess)
        coEvery { AndroidCloudVaultKeyAccess.keyForReading(any(), any()) } returns null
    }

    @After
    fun restoreVaultKeyAccess() {
        unmockkObject(AndroidCloudVaultKeyAccess)
    }

    private fun authWithUid(uid: String?): FirebaseAuth {
        val user =
            uid?.let { signedInUid ->
                val mockedUser = mockk<FirebaseUser>()
                every { mockedUser.uid } returns signedInUid
                mockedUser
            }
        return mockk {
            every { currentUser } returns user
        }
    }

    private fun firestoreWithCliSessions(uid: String, sessionsTask: () -> Task<QuerySnapshot>): FirebaseFirestore {
        val limited = mockk<Query> {
            every { get() } answers { sessionsTask() }
        }
        val ordered = mockk<Query> {
            every { limit(any()) } returns limited
        }
        val cliSessions = mockk<CollectionReference> {
            every { orderBy("updatedAt", Query.Direction.DESCENDING) } returns ordered
        }
        val userDocument = mockk<DocumentReference> {
            every { collection("cli_sessions") } returns cliSessions
        }
        val usersCollection = mockk<CollectionReference> {
            every { document(uid) } returns userDocument
        }
        return mockk {
            every { collection("users") } returns usersCollection
        }
    }

    private fun emptySnapshot(): QuerySnapshot = mockk {
        every { documents } returns emptyList()
    }

    private fun transientFailure(): FirebaseFirestoreException = FirebaseFirestoreException(
        "App Check token is temporarily unavailable.",
        FirebaseFirestoreException.Code.UNAVAILABLE,
    )

    @Test
    fun `refresh is a no-op while a load is already in flight`(): TestResult = runTest {
        val store = ThreadInboxStore(firestore = mockk(), auth = mockk())
        store.beginLoading()

        store.refreshFromCloud()

        assertTrue(store.isLoading)
    }

    @Test
    fun `signed-out refresh clears the inbox without retrying`(): TestResult = runTest {
        val store = ThreadInboxStore(firestore = mockk(), auth = authWithUid(null))

        store.refreshFromCloud()

        assertTrue(store.items.isEmpty())
        assertNull(store.lastRefreshedAtEpoch)
        assertNull(store.refreshError)
        assertFalse(store.isLoading)
    }

    @Test
    fun `transient firebase failures retry with doubling backoff then succeed`(): TestResult = runTest {
        var attempts = 0
        val firestore =
            firestoreWithCliSessions("uid-1") {
                attempts += 1
                if (attempts <= 2) {
                    Tasks.forException(transientFailure())
                } else {
                    Tasks.forResult(emptySnapshot())
                }
            }
        val store = ThreadInboxStore(firestore = firestore, auth = authWithUid("uid-1"))

        store.refreshFromCloud()

        assertEquals(3, attempts)
        assertEquals(
            inboxRefreshRetryDelayMillis(1) + inboxRefreshRetryDelayMillis(2),
            currentTime,
        )
        assertNull(store.refreshError)
        assertNotNull(store.lastRefreshedAtEpoch)
        assertTrue(store.items.isEmpty())
        assertFalse(store.isLoading)
    }

    @Test
    fun `refresh gives up after the bounded retry budget`(): TestResult = runTest {
        var attempts = 0
        val firestore =
            firestoreWithCliSessions("uid-1") {
                attempts += 1
                Tasks.forException(transientFailure())
            }
        val store = ThreadInboxStore(firestore = firestore, auth = authWithUid("uid-1"))

        store.refreshFromCloud()

        assertEquals(1 + INBOX_REFRESH_MAX_RETRIES, attempts)
        assertEquals(
            inboxRefreshRetryDelayMillis(1) + inboxRefreshRetryDelayMillis(2) + inboxRefreshRetryDelayMillis(3),
            currentTime,
        )
        assertNotNull(store.refreshError)
        assertNull(store.lastRefreshedAtEpoch)
        assertFalse(store.isLoading)
    }

    @Test
    fun `cancellation is rethrown instead of being retried`() {
        var attempts = 0
        val firestore =
            firestoreWithCliSessions("uid-1") {
                attempts += 1
                throw CancellationException("caller scope cancelled")
            }
        val store = ThreadInboxStore(firestore = firestore, auth = authWithUid("uid-1"))

        assertThrows(CancellationException::class.java) {
            runBlocking { store.refreshFromCloud() }
        }

        assertEquals(1, attempts)
        assertFalse(store.isLoading)
    }
}
