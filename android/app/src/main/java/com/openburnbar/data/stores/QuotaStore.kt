package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.isExplicitlyStale
import com.openburnbar.data.models.isStale
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import java.time.Instant

class QuotaStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
    private val functions: FunctionsRepository = FunctionsRepository()
) : ViewModel() {
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

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                _accounts.value = repo.fetchProviderAccounts()
                refreshStaleCloudQuotaIfPossible()
            } catch (e: Exception) {
                _error.value = e.message
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
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun startListening() {
        listenJob?.cancel()
        startAutomaticRefresh()
        listenJob = viewModelScope.launch {
            // See ActivityStore.startListening for the rationale —
            // Firestore listener errors must NEVER reach
            // Dispatchers.Main.immediate as unhandled exceptions.
            repo.listenToQuotaSnapshots()
                .catch { e -> _error.value = e.message ?: e::class.simpleName }
                .collect { snapshots ->
                    _snapshots.value = snapshots.dedupeFresh()
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
        automaticRefreshJob = viewModelScope.launch {
            while (true) {
                delay(15 * 60 * 1000L)
                refreshStaleCloudQuotaIfPossible(maxRefreshes = 10)
            }
        }
    }

    private fun refreshStaleCloudQuotaIfPossible(maxRefreshes: Int = 3) {
        val snapshotByAccount = _snapshots.value
            .filter { !it.accountId.isNullOrBlank() }
            .groupBy { it.accountId.orEmpty() }
        val accountsToRefresh = _accounts.value
            .filter { it.status in setOf("connected", "stale", "error") }
            .filter { it.storageScope in setOf("cloud_refreshable", "server_private") }
            .filter { account ->
                val accountSnapshots = snapshotByAccount[account.id].orEmpty()
                accountSnapshots.isEmpty() || accountSnapshots.any { it.isStale() }
            }
            .filter { staleRefreshInFlight.add(it.id) }
            .take(maxRefreshes)

        if (accountsToRefresh.isEmpty()) return
        viewModelScope.launch {
            for (account in accountsToRefresh) {
                try {
                    functions.refreshProviderAccountQuota(account.id)
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
        }
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
        val providerKey = AgentProvider.fromKey(s.provider)?.key
            ?: AgentProvider.fromKey(s.providerId)?.key
            ?: s.provider.lowercase().filter { it.isLetterOrDigit() }.ifBlank { s.provider }
        val accountKey = s.accountId?.takeIf { it.isNotBlank() }
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

    val providerOrder = AgentProvider.entries.withIndex().associate { (i, p) -> p.key to i }
    return freshest.values.sortedWith(
        compareBy(
            { providerOrder[AgentProvider.fromKey(it.provider)?.key] ?: Int.MAX_VALUE },
            { it.accountLabel.orEmpty().lowercase() }
        )
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
