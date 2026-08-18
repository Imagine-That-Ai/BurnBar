package com.openburnbar.data.stores

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.isExplicitlyStale
import com.openburnbar.data.models.isStale
import com.openburnbar.data.policy.UidScopedCacheRegistry
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

private const val AUTO_REFRESH_PERIOD_MINUTES = 15
private const val SECONDS_PER_MINUTE = 60
private const val CONNECT_TIMEOUT_SECONDS = 15L
private const val READ_TIMEOUT_SECONDS = 30L

class QuotaStore(
    application: Application,
    private val repo: FirestoreRepository = FirestoreRepository(),
    functions: FunctionsRepository? = null,
    private val httpClient: OkHttpClient = defaultClient(),
    scopedCaches: UidScopedCacheRegistry = UidScopedCacheRegistry.shared,
) : AndroidViewModel(application) {
    constructor(application: Application) : this(application, FirestoreRepository(), null, defaultClient())

    constructor(
        repo: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository? = null,
    ) : this(Application(), repo, functions, defaultClient())

    private val functions: FunctionsRepository by lazy { functions ?: FunctionsRepository() }

    private val _snapshots = MutableStateFlow<List<ProviderQuotaSnapshot>>(emptyList())
    val snapshots = _snapshots.asStateFlow()

    private val _accounts = MutableStateFlow<List<ProviderAccount>>(emptyList())
    val accounts = _accounts.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private var listenJob: Job? = null
    private var automaticRefreshJob: Job? = null
    private val staleRefreshInFlight = mutableSetOf<String>()

    init {
        scopedCaches.register { clearCache() }
    }

    fun clearCache() {
        listenJob?.cancel()
        automaticRefreshJob?.cancel()
        listenJob = null
        automaticRefreshJob = null
        staleRefreshInFlight.clear()
        _snapshots.value = emptyList()
        _accounts.value = emptyList()
        _isLoading.value = false
        _error.value = null
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                _accounts.value = repo.fetchProviderAccounts()
                refreshStaleCloudQuotaIfPossible()
                _error.value = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: FirestoreRepository.NotSignedInException) {
                _snapshots.value = emptyList()
                _accounts.value = emptyList()
                _error.value = e.message ?: "Sign in required."
            } catch (e: FirebaseException) {
                _error.value = e.message ?: e::class.simpleName
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                _accounts.value = repo.fetchProviderAccounts()
                refreshStaleCloudQuotaIfPossible()
                _error.value = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: FirestoreRepository.NotSignedInException) {
                _snapshots.value = emptyList()
                _accounts.value = emptyList()
                _error.value = e.message ?: "Sign in required."
            } catch (e: FirebaseException) {
                _error.value = e.message ?: e::class.simpleName
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun startListening() {
        listenJob?.cancel()
        startAutomaticRefresh()
        listenJob =
            viewModelScope.launch {
                // See ActivityStore.startListening for the rationale —
                // Firestore listener errors must NEVER reach
                // Dispatchers.Main.immediate as unhandled exceptions.
                repo.listenToQuotaSnapshotUpdates()
                    .catch { e ->
                        if (e is FirestoreRepository.NotSignedInException) {
                            _snapshots.value = emptyList()
                            _accounts.value = emptyList()
                        }
                        _error.value = e.message ?: e::class.simpleName
                    }
                    .collect { update ->
                        val incoming = update.snapshots.dedupeFresh()
                        _snapshots.value =
                            if (update.isFromCache && _snapshots.value.isNotEmpty()) {
                                (_snapshots.value + incoming).dedupeFresh()
                            } else {
                                incoming
                            }
                        refreshStaleCloudQuotaIfPossible()
                    }
            }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
        automaticRefreshJob?.cancel()
        automaticRefreshJob = null
    }

    private fun startAutomaticRefresh() {
        if (automaticRefreshJob != null) return
        automaticRefreshJob =
            viewModelScope.launch {
                while (true) {
                    delay(AUTO_REFRESH_PERIOD_MINUTES * SECONDS_PER_MINUTE * 1000L)
                    refreshStaleCloudQuotaIfPossible(maxRefreshes = 10)
                }
            }
    }

    private fun refreshStaleCloudQuotaIfPossible(maxRefreshes: Int = 3) {
        val snapshotByAccount =
            _snapshots.value
                .filter { !it.accountId.isNullOrBlank() }
                .groupBy { it.accountId.orEmpty() }
        val accountsToRefresh =
            _accounts.value
                .filter { it.status in setOf("connected", "stale", "error") }
                .filter { account ->
                    account.storageScope in setOf("cloud_refreshable", "server_private") ||
                        account.storageScope == "local_only" &&
                        account.providerId in setOf("claude-code", "codex")
                }
                .filter { account ->
                    val accountSnapshots = snapshotByAccount[account.id].orEmpty()
                    accountSnapshots.isEmpty() || accountSnapshots.any { it.isStale() }
                }
                .filter { staleRefreshInFlight.add(it.id) }
                .take(maxRefreshes)

        if (accountsToRefresh.isEmpty()) return
        viewModelScope.launch {
            try {
                for (account in accountsToRefresh) {
                    try {
                        if (account.storageScope == "local_only" &&
                            account.providerId in setOf("claude-code", "codex")
                        ) {
                            refreshSelfHostedRunner(account)
                        } else {
                            functions.refreshProviderAccountQuota(account.id)
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        // Firestore remains the source of truth; refresh failures
                        // are reflected by provider account and snapshot docs.
                    } finally {
                        staleRefreshInFlight.remove(account.id)
                    }
                }
                runCatching {
                    _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                    _accounts.value = repo.fetchProviderAccounts()
                }
            } finally {
                // If cancellation exits the loop early, remaining queued ids
                // that never reached their per-account finally must be cleared
                // so they are not stuck in staleRefreshInFlight forever.
                for (account in accountsToRefresh) {
                    staleRefreshInFlight.remove(account.id)
                }
            }
        }
    }

    private suspend fun refreshSelfHostedRunner(account: ProviderAccount) {
        val runnerStore = SelfHostedQuotaRunnerStore(getApplication())
        val config = runnerStore.config.value
        if (!config.isEnabled || config.endpointUrl.isBlank()) return
        val baseUrl = config.endpointUrl.trim().trimEnd('/')
        val url = "$baseUrl/v1/quota/refresh"
        val jsonBody =
            JSONObject().apply {
                put("provider", account.providerId)
                put("accountID", account.id)
            }.toString()
        val requestBody =
            jsonBody.toByteArray()
                .toRequestBody("application/json".toMediaType())
        val requestBuilder =
            Request.Builder()
                .url(url)
                .post(requestBody)
        if (config.apiKey.isNotBlank()) {
            requestBuilder.addHeader("Authorization", "Bearer ${config.apiKey}")
        }
        val request = requestBuilder.build()
        withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    _error.value = "Self-hosted runner returned HTTP ${response.code}"
                    return@use
                }
                val raw = response.body?.string().orEmpty()
                if (raw.isBlank()) {
                    _error.value = "Self-hosted runner returned an empty response body."
                    return@use
                }
                // The runner returns a sanitized quota snapshot, either at the
                // top level or nested under "snapshot" (iOS pattern). Enrich
                // it with the account context the runner doesn't know, then
                // upload via the callable so Firestore is the single source of
                // truth — mirroring SelfHostedQuotaRunnerStore.refresh on iOS.
                var payload = JSONObject(raw)
                if (payload.has("snapshot") && payload.optJSONObject("snapshot") != null) {
                    payload = payload.getJSONObject("snapshot")
                }
                val now = Instant.now().toString()
                payload.put("provider", account.providerId)
                payload.put("providerID", account.providerId)
                payload.put("accountID", account.id)
                payload.put("accountLabel", account.label)
                payload.put("accountStorageScope", "local_only")
                payload.put("sourceKind", "provider")
                payload.put("sourceId", payload.optString("sourceId").ifBlank { "self-hosted-runner" })
                payload.put("fetchedAt", payload.optString("fetchedAt").ifBlank { now })
                payload.put("source", payload.optString("source").ifBlank { "Self-hosted quota runner" })
                payload.put("confidence", payload.optString("confidence").ifBlank { "high" })
                payload.put("schemaVersion", payload.optInt("schemaVersion", 2))
                payload.put("updatedAt", now)
                functions.uploadProviderQuotaSnapshot(jsonToMap(payload))
                // Re-fetch from Firestore after the snapshot is uploaded so
                // the UI reflects the server-sanitized document.
                _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                _accounts.value = repo.fetchProviderAccounts()
            }
        }
    }

    /**
     * Converts a [JSONObject] to a [Map] using only the Android SDK's
     * [JSONObject.keys] and [JSONObject.get] — the standalone org.json
     * [JSONObject.toMap] is not available on the Android compile classpath.
     */
    private fun jsonToMap(json: JSONObject): Map<String, Any> {
        val map = mutableMapOf<String, Any>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = json.get(key)
        }
        return map
    }

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()
    }
}

/**
 * Collapse the raw Firestore snapshot list so each (provider, account) pair is
 * represented by a single, freshest record. The data layer is inconsistent —
 * iOS callers, the Mac daemon, and the cloud function all write quota docs
 * with subtly different keys ("codex", "Codex", "claudecode"), so without
 * normalization the UI rendered the same account several times. We:
 *   1. Normalize the provider key via `AgentProvider.fromKey()` (which lowers,
 *      strips non-alphanumerics, and resolves aliases like "claudecode" →
 *      CLAUDE_CODE). Fallback to the raw key when no enum match exists so
 *      genuinely unknown providers still render once each.
 *   2. Pick a stable account discriminator: `accountId`, else `sourceId`,
 *      else `accountLabel`, else "".
 *   3. Within each group, keep the entry whose `updatedAt` (then `fetchedAt`)
 *      ISO timestamp is the most recent. Snapshots without buckets sink to
 *      the bottom of the freshness comparison so an empty placeholder never
 *      hides a real bucketed record.
 *   4. Sort the result deterministically: providers in `AgentProvider.entries`
 *      order, then account label alphabetical.
 */
internal fun List<ProviderQuotaSnapshot>.dedupeFresh(): List<ProviderQuotaSnapshot> {
    if (size < 2) return this

    fun groupKey(s: ProviderQuotaSnapshot): String {
        val providerKey =
            AgentProvider.fromKey(s.provider)?.key
                ?: AgentProvider.fromKey(s.providerId)?.key
                ?: s.provider.lowercase().filter { it.isLetterOrDigit() }.ifBlank { s.provider }
        val accountKey =
            s.accountId?.takeIf { it.isNotBlank() }
                ?: s.sourceId.takeIf { it.isNotBlank() }
                ?: s.accountLabel?.takeIf { it.isNotBlank() }
                ?: ""
        return "$providerKey|$accountKey"
    }

    val freshest = LinkedHashMap<String, ProviderQuotaSnapshot>()
    for (snap in this) {
        val key = groupKey(snap)
        val incumbent = freshest[key]
        if (incumbent == null || isFresher(snap, incumbent)) {
            freshest[key] = snap
        }
    }

    return freshest.values.sortedWith(
        compareBy(
            { (AgentProvider.fromKey(it.provider)?.key ?: it.provider).lowercase() },
            { (it.accountId ?: it.accountLabel.orEmpty()).lowercase() },
        ),
    )
}

private fun isFresher(candidate: ProviderQuotaSnapshot, incumbent: ProviderQuotaSnapshot): Boolean {
    // A fresh stale-marker/tombstone must beat old bucketed quota data;
    // otherwise deleted or failed credentials can keep rendering fake quota.
    val candidateStale = candidate.isExplicitlyStale || candidate.isStale()
    val incumbentStale = incumbent.isExplicitlyStale || incumbent.isStale()
    if (candidateStale != incumbentStale) {
        return freshnessMillis(candidate) >= freshnessMillis(incumbent)
    }

    // A record with real buckets beats an empty placeholder only when neither
    // side is stale.
    val candidateHasBuckets = candidate.buckets.isNotEmpty()
    val incumbentHasBuckets = incumbent.buckets.isNotEmpty()
    if (candidateHasBuckets != incumbentHasBuckets) return candidateHasBuckets

    val candidateAt = freshnessMillis(candidate)
    val incumbentAt = freshnessMillis(incumbent)
    return candidateAt > incumbentAt
}

private fun freshnessMillis(s: ProviderQuotaSnapshot): Long {
    listOf(s.updatedAt, s.fetchedAt).forEach { iso ->
        if (!iso.isNullOrBlank()) {
            runCatching { return@freshnessMillis Instant.parse(iso).toEpochMilli() }
        }
    }
    return Long.MIN_VALUE
}
