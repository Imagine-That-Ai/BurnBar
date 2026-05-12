package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant

class QuotaStore(
    private val repo: FirestoreRepository = FirestoreRepository()
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

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _snapshots.value = repo.fetchQuotaSnapshots().dedupeFresh()
                _accounts.value = repo.fetchProviderAccounts()
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
        listenJob = viewModelScope.launch {
            repo.listenToQuotaSnapshots().collect { snapshots ->
                _snapshots.value = snapshots.dedupeFresh()
            }
        }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
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
    // A record with real buckets always beats an empty placeholder.
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
