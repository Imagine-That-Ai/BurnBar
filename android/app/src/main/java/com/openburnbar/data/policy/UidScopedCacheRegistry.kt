package com.openburnbar.data.policy

/**
 * Stores register a clearer so an account switch cannot keep the previous UID's
 * in-memory snapshots. Fail-closed: missing registration just means that store
 * must also check [MobileAuthSessionPolicy.shouldServeCachedData].
 */
class UidScopedCacheRegistry {
    private val lock = Any()
    private val clearers = mutableListOf<() -> Unit>()

    fun register(clearer: () -> Unit) {
        synchronized(lock) { clearers.add(clearer) }
    }

    fun clearAll() {
        val snapshot = synchronized(lock) { clearers.toList() }
        snapshot.forEach { it() }
    }

    companion object {
        val shared = UidScopedCacheRegistry()
    }
}
