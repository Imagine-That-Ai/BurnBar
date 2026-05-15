package com.openburnbar.data.square

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

// MARK: - Thread Inbox Store (Android parity)
//
// Aggregator that holds the merged list of inbox items + last-refresh
// timestamp. The Android Phase A surface seeds this with stubs until the
// existing Hermes / Pi / CLI mirror stores publish to it. Phase B wires
// the per-runtime stores.

class ThreadInboxStore private constructor() {
    var items by mutableStateOf<List<ThreadInboxItem>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var lastRefreshedAtEpoch by mutableStateOf<Long?>(null)
        private set

    fun replace(items: List<ThreadInboxItem>) {
        this.items = items.sortedForInbox()
        this.lastRefreshedAtEpoch = System.currentTimeMillis()
        this.isLoading = false
    }

    fun beginLoading() {
        isLoading = true
    }

    companion object {
        @Volatile
        private var instance: ThreadInboxStore? = null

        fun shared(): ThreadInboxStore =
            instance ?: synchronized(this) {
                instance ?: ThreadInboxStore().also { instance = it }
            }
    }
}
