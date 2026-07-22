package com.openburnbar

import android.os.Process
import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.QuerySnapshot
import com.google.firebase.firestore.Source
import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.stores.ActivityStore
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestResult
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * Regression tests for the P-CQ-3 CancellationException rethrow fix.
 *
 * Pre-fix, several `catch (_: Exception)` blocks swallowed
 * [CancellationException], breaking structured-concurrency cancellation.
 * Post-fix, each catch is preceded by
 * `catch (e: CancellationException) { throw e }`.
 *
 * 5. [FirestoreRepository.fetchQuotaSnapshots] and
 *    [FirestoreRepository.fetchProviderAccounts] rethrow
 *    CancellationException instead of swallowing it and falling through to
 *    `Source.DEFAULT`.
 * 6. [ActivityStore.updateSearch] rethrows CancellationException from the
 *    cloud search service instead of swallowing it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CancellationRethrowTest {

    private val testDispatcher = StandardTestDispatcher()

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule(testDispatcher)

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { Log.d(any(), any(), any()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkStatic(com.google.firebase.FirebaseApp::class)
        unmockkStatic(FirebaseFirestore::class)
        unmockkStatic(FirebaseFunctions::class)
        unmockkStatic(FirebaseAuth::class)
        unmockkStatic(Log::class)
        unmockkStatic(Process::class)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 5a: fetchQuotaSnapshots rethrows CancellationException
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `fetchQuotaSnapshots rethrows CancellationException instead of falling through to Source DEFAULT`(): TestResult = runTest(testDispatcher) {
        val firestore = mockFirestoreForCancellation("quota_snapshots")
        mockFirebaseAuth("uid-1")
        mockFirebaseSingletons(firestore)
        val repo = FirestoreRepository()

        val thrown = assertThrows(CancellationException::class.java) {
            runBlocking { repo.fetchQuotaSnapshots() }
        }
        assertTrue("CancellationException should propagate", thrown is CancellationException)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 5b: fetchProviderAccounts rethrows CancellationException
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `fetchProviderAccounts rethrows CancellationException instead of falling through to Source DEFAULT`(): TestResult = runTest(testDispatcher) {
        val firestore = mockFirestoreForCancellation("provider_accounts")
        mockFirebaseAuth("uid-1")
        mockFirebaseSingletons(firestore)
        val repo = FirestoreRepository()

        val thrown = assertThrows(CancellationException::class.java) {
            runBlocking { repo.fetchProviderAccounts() }
        }
        assertTrue("CancellationException should propagate", thrown is CancellationException)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 6: ActivityStore.updateSearch rethrows CancellationException
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `updateSearch rethrows CancellationException from cloud search instead of swallowing it`(): TestResult = runTest(testDispatcher) {
        // Phase 1: a successful search populates cloudSearchHits so we
        // have a non-empty baseline that distinguishes the two code paths.
        val realRow = CloudConversationSearchRow(
            id = "r1",
            documentID = "doc-1",
            title = "Baseline",
            snippet = "snippet",
            provider = "codex",
            storagePath = "/path",
            bodyHash = "hash",
            bodyHashVersion = 1,
            score = 1.0,
        )
        val mockSearchService = mockk<CloudConversationSearchService>()
        coEvery { mockSearchService.search(any(), any()) } returns listOf(realRow)

        // Pass a mock repo so ActivityStore's constructor doesn't call
        // FirestoreRepository() (which needs Firebase).
        val mockRepo = mockk<FirestoreRepository>(relaxed = true)
        val store = ActivityStore(
            repo = mockRepo,
            cloudSearchFactory = { mockSearchService },
        )
        store.updateSearch("baseline query")
        advanceUntilIdle()
        assertTrue(
            "baseline search should have produced results",
            store.cloudSearchHits.value.isNotEmpty(),
        )

        // Phase 2: the next search throws CancellationException.
        coEvery { mockSearchService.search(any(), any()) } throws
            CancellationException("test-cancel")
        store.updateSearch("cancel query")
        advanceUntilIdle()

        // Pre-fix: catch (_: Exception) swallows the CancellationException
        // and sets _cloudSearchHits.value = emptyList() → the baseline
        // hits are cleared.
        //
        // Post-fix: catch (e: CancellationException) { throw e } rethrows
        // BEFORE the catch (_: Exception) fallback runs, so
        // _cloudSearchHits is NOT cleared and the baseline hits remain.
        assertTrue(
            "pre-fix: swallowed CancellationException cleared the " +
                "baseline hits (expected post-fix to preserve them): " +
                "${store.cloudSearchHits.value}",
            store.cloudSearchHits.value.isNotEmpty(),
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Mocks the Firebase singleton accessors so [FirestoreRepository] can be
     * constructed in a JVM test. `Firebase.firestore` (KTX) delegates to
     * `FirebaseFirestore.getInstance()`; `Firebase.functions` (KTX) delegates
     * to `FirebaseFunctions.getInstance()`. Also stubs `Process.myPid()`
     * which is called internally by FirebaseApp.getInstance().
     */
    private fun mockFirebaseSingletons(firestore: FirebaseFirestore) {
        mockkStatic(Process::class)
        every { Process.myPid() } returns 1

        // FirebaseFunctions.getInstance() (Kotlin companion) internally calls
        // FirebaseApp.getInstance(), which throws if Firebase isn't
        // initialized. Mock it first so MockK can record the getInstance
        // stubs without triggering the real FirebaseApp lookup.
        val mockFirebaseApp = mockk<com.google.firebase.FirebaseApp>(relaxed = true)
        mockkStatic(com.google.firebase.FirebaseApp::class)
        every { com.google.firebase.FirebaseApp.getInstance() } returns mockFirebaseApp
        every { com.google.firebase.FirebaseApp.getInstance(any<String>()) } returns mockFirebaseApp

        mockkStatic(FirebaseFirestore::class)
        every { FirebaseFirestore.getInstance() } returns firestore
        every { FirebaseFirestore.getInstance(any<com.google.firebase.FirebaseApp>()) } returns firestore

        mockkStatic(FirebaseFunctions::class)
        val mockFunctions = mockk<FirebaseFunctions>(relaxed = true)
        every { FirebaseFunctions.getInstance() } returns mockFunctions
    }

    /** Mocks FirebaseAuth.getInstance().currentUser.uid to [uid]. */
    private fun mockFirebaseAuth(uid: String) {
        mockkStatic(FirebaseAuth::class)
        val mockAuth = mockk<FirebaseAuth>(relaxed = true)
        val mockUser = mockk<com.google.firebase.auth.FirebaseUser>(relaxed = true)
        every { FirebaseAuth.getInstance() } returns mockAuth
        every { mockAuth.currentUser } returns mockUser
        every { mockUser.uid } returns uid
    }

    /**
     * Creates a mock [FirebaseFirestore] where the [collectionName]
     * collection's `.get(Source.SERVER)` throws [CancellationException]
     * directly (before `.await()` is called), while `.get(Source.DEFAULT)`
     * returns an empty snapshot.
     *
     * Pre-fix: `catch (_: Exception)` swallows the CancellationException and
     * falls through to `Source.DEFAULT` → returns empty list → no exception.
     * Post-fix: `catch (e: CancellationException) { throw e }` rethrows →
     * CancellationException propagates.
     */
    private fun mockFirestoreForCancellation(collectionName: String): FirebaseFirestore {
        val targetCollection = mockk<CollectionReference>()
        every { targetCollection.get(Source.SERVER) } throws
            CancellationException("test-cancel")
        val emptySnapshot = mockk<QuerySnapshot>(relaxed = true) {
            every { documents } returns emptyList()
        }
        every { targetCollection.get(Source.DEFAULT) } returns
            com.google.android.gms.tasks.Tasks.forResult(emptySnapshot)

        val userDocument = mockk<DocumentReference>(relaxed = true) {
            every { collection(collectionName) } returns targetCollection
        }
        val usersCollection = mockk<CollectionReference>(relaxed = true) {
            every { document(any()) } returns userDocument
        }
        return mockk<FirebaseFirestore>(relaxed = true) {
            every { collection("users") } returns usersCollection
        }
    }
}
