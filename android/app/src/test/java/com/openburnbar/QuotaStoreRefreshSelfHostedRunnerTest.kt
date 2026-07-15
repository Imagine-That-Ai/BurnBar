package com.openburnbar

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.stores.QuotaStore
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestResult
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Regression tests for the P-CQ-3 Android quota-refresh fix in
 * [QuotaStore.refreshSelfHostedRunner] and
 * [QuotaStore.refreshStaleCloudQuotaIfPossible].
 *
 * Each test fails on the pre-fix code (origin/main) and passes on the
 * post-fix code:
 *
 * 1. **IO dispatch** — pre-fix the OkHttp call ran on the Main/calling
 *    thread (no `withContext(Dispatchers.IO)`); post-fix it runs on the
 *    IO pool.
 * 2. **JSON escaping** — pre-fix the request body was built with raw
 *    string interpolation (unescaped quotes break JSON); post-fix
 *    `JSONObject` escapes properly.
 * 3. **Observable failure** — pre-fix ALL exceptions were swallowed in
 *    `catch (_: Exception)` and `_error` was never set; post-fix HTTP
 *    errors set `_error`.
 * 4. **CancellationException rethrow** — pre-fix `CancellationException`
 *    was swallowed by `catch (_: Exception)`; post-fix it is rethrown,
 *    preventing the trailing `runCatching` re-fetch from running.
 *
 * **Pre-fix note:** The 4th constructor parameter (`httpClient`) does not
 * exist on origin/main, so these tests fail to compile against the pre-fix
 * source — the compilation failure IS the expected pre-fix failure.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class QuotaStoreRefreshSelfHostedRunnerTest {

    /**
     * StandardTestDispatcher so `withContext(Dispatchers.IO)` actually
     * runs on the real IO pool instead of being elided by an unconfined
     * dispatcher.
     */
    private val testDispatcher = StandardTestDispatcher()

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule(testDispatcher)

    @Before
    fun setUp() {
        // ProviderQuotaSnapshot.isStale() calls android.util.Log.d — stub
        // it to avoid the "not mocked" RuntimeException in JVM unit tests.
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { Log.d(any(), any(), any()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 1: IO dispatch — refreshSelfHostedRunner runs OkHttp off Main
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `refreshSelfHostedRunner executes the OkHttp call on a non-Main thread`(): TestResult =
        runTest(testDispatcher) {
            val testThread = Thread.currentThread()
            val capturedThread = arrayOfNulls<Thread>(1)
            val latch = CountDownLatch(1)
            val client = okHttpClient(Interceptor { chain ->
                capturedThread[0] = Thread.currentThread()
                latch.countDown()
                stubOkResponse(chain.request())
            })

            val mockRepo = mockRepoWithStaleCodexAccount()
            val store = QuotaStore(stubApp(), mockRepo, null, client)
            store.load()
            advanceUntilIdle()
            awaitIoAndAdvance(latch)

            val interceptorThread = capturedThread[0]
            assertNotNull("interceptor thread was not captured", interceptorThread)
            assertFalse(
                "OkHttp call ran on the test/Main thread (${interceptorThread?.name})",
                interceptorThread === testThread,
            )
        }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 2: JSON body escapes a quote in the account id via JSONObject
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `refreshSelfHostedRunner escapes a quote in the account id via JSONObject`(): TestResult =
        runTest(testDispatcher) {
            val capturedBody = mutableListOf<String>()
            val latch = CountDownLatch(1)
            val client = okHttpClient(Interceptor { chain ->
                val buffer = okio.Buffer()
                chain.request().body?.writeTo(buffer)
                capturedBody.add(buffer.readUtf8())
                latch.countDown()
                stubOkResponse(chain.request())
            })

            // providerId must be "codex" to pass the refresh filter; the
            // quote goes in the account id, which is also interpolated into
            // the JSON body.
            val account = ProviderAccount(
                id = "acc\"evil",
                providerId = "codex",
                status = "stale",
                storageScope = "local_only",
            )
            val mockRepo = mockRepoWithAccount(account)
            val store = QuotaStore(stubApp(), mockRepo, null, client)
            store.load()
            advanceUntilIdle()
            awaitIoAndAdvance(latch)

            assertTrue("request body was never captured", capturedBody.isNotEmpty())
            // Pre-fix: raw string interpolation produces
            //   {"provider":"codex","accountID":"acc"evil"}
            // which is invalid JSON — JSONObject throws.
            // Post-fix: JSONObject escapes the quote → valid JSON.
            val json = JSONObject(capturedBody.first())
            assertEquals("codex", json.getString("provider"))
            assertEquals("acc\"evil", json.getString("accountID"))
        }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 3: Observable failure — HTTP error sets _error StateFlow
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `refreshSelfHostedRunner sets error state on HTTP failure`(): TestResult =
        runTest(testDispatcher) {
            val latch = CountDownLatch(1)
            val client = okHttpClient(Interceptor { chain ->
                latch.countDown()
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(500)
                    .message("Internal Server Error")
                    .body("".toResponseBody("text/plain".toMediaType()))
                    .build()
            })

            val mockRepo = mockRepoWithStaleCodexAccount()
            val store = QuotaStore(stubApp(), mockRepo, null, client)
            store.load()
            advanceUntilIdle()
            awaitIoAndAdvance(latch)

            // Pre-fix: catch (_: Exception) swallowed the failure and
            // _error stayed null.  Post-fix: the HTTP 500 sets _error.
            val error = store.error.value
            assertNotNull("error state was not set on HTTP 500", error)
            assertTrue("error should mention HTTP 500: $error", error!!.contains("500"))
        }

    // ─────────────────────────────────────────────────────────────────────
    //  Test 4: CancellationException is not swallowed in
    //           refreshStaleCloudQuotaIfPossible
    // ─────────────────────────────────────────────────────────────────────

    @Test
    fun `refreshStaleCloudQuotaIfPossible rethrows CancellationException from the runner call`(): TestResult =
        runTest(testDispatcher) {
            val latch = CountDownLatch(1)
            val client = okHttpClient(Interceptor { chain ->
                latch.countDown()
                throw CancellationException("test-cancellation")
            })

            val mockRepo = mockRepoWithStaleCodexAccount()
            val store = QuotaStore(stubApp(), mockRepo, null, client)
            store.load()
            advanceUntilIdle()
            awaitIoAndAdvance(latch)

            // Post-fix: catch (e: CancellationException) { throw e } rethrows
            // → the coroutine is cancelled BEFORE the trailing runCatching
            // re-fetch → fetchQuotaSnapshots called exactly once (from load).
            //
            // Pre-fix: catch (_: Exception) swallows the CancellationException
            // → the coroutine continues → runCatching calls
            // fetchQuotaSnapshots again → 2 total calls → coVerify fails.
            coVerify(exactly = 1) { mockRepo.fetchQuotaSnapshots() }
        }

    // ─────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Waits for the IO-thread interceptor to fire ([latch]), then sleeps
     * briefly to let the IO thread finish processing the response and
     * dispatch the continuation back to the test dispatcher, then
     * [advanceUntilIdle] to process that continuation.
     *
     * `advanceUntilIdle` alone cannot wait for `Dispatchers.IO` — it only
     * advances the test scheduler. The `latch` + sleep bridges the gap
     * between the real IO pool and the virtual-time test scheduler.
     */
    private suspend fun kotlinx.coroutines.test.TestScope.awaitIoAndAdvance(latch: CountDownLatch) {
        assertTrue("interceptor did not fire within timeout", latch.await(10, TimeUnit.SECONDS))
        // Give the IO thread time to finish the withContext block and
        // dispatch the continuation back to the Main (test) dispatcher.
        Thread.sleep(500)
        advanceUntilIdle()
        // One more pass in case the runCatching re-fetch at the end of
        // refreshStaleCloudQuotaIfPossible scheduled additional tasks.
        Thread.sleep(200)
        advanceUntilIdle()
    }

    /**
     * Creates a mock Application whose `getSharedPreferences` returns a
     * mock with the self-hosted runner enabled. This lets the real
     * `SelfHostedQuotaRunnerStore` construct without `mockkConstructor`
     * — it reads `endpointUrl`, `apiKey`, and `isEnabled` from prefs.
     */
    private fun stubApp(): Application {
        val prefs = mockk<SharedPreferences>()
        every { prefs.getString("endpointUrl", "") } returns "http://stub.invalid"
        every { prefs.getString("apiKey", "") } returns ""
        every { prefs.getBoolean("isEnabled", false) } returns true
        // SelfHostedQuotaRunnerStore calls context.applicationContext first.
        val app = mockk<Application>()
        every { app.applicationContext } returns app
        every { app.getSharedPreferences("selfHostedRunner", Context.MODE_PRIVATE) } returns prefs
        return app
    }

    private fun staleCodexAccount(): ProviderAccount = ProviderAccount(
        id = "acc-1",
        providerId = "codex",
        status = "stale",
        storageScope = "local_only",
    )

    /** Builds a relaxed mock FirestoreRepository pre-stubbed with an empty
     *  snapshot list and a single stale codex account that triggers the
     *  self-hosted refresh path. */
    private fun mockRepoWithStaleCodexAccount(): FirestoreRepository =
        mockRepoWithAccount(staleCodexAccount())

    private fun mockRepoWithAccount(account: ProviderAccount): FirestoreRepository {
        val mockRepo = mockk<FirestoreRepository>(relaxed = true)
        coEvery { mockRepo.fetchQuotaSnapshots() } returns emptyList()
        coEvery { mockRepo.fetchProviderAccounts() } returns listOf(account)
        every { mockRepo.listenToQuotaSnapshots() } returns flowOf(emptyList())
        return mockRepo
    }

    private fun okHttpClient(interceptor: Interceptor): OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .addInterceptor(interceptor)
            .build()

    private fun stubOkResponse(request: okhttp3.Request): Response =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body("{}".toResponseBody("application/json".toMediaType()))
            .build()
}