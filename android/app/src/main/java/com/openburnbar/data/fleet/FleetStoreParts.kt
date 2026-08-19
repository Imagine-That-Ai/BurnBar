package com.openburnbar.data.fleet

// MARK: - Fleet store pure parts (no Firebase)
//
// Everything between "a mirror document arrived" and "a state is on screen"
// lives here as pure functions over plain data, exercised by JVM unit tests.
// `FleetStore` supplies the Firestore listener and vault plumbing and nothing
// else — the same split `AIInboxStore` / `AIInboxRefreshParts` uses.

/** The mirror document, after unsealing/parsing (either part may have failed). */
data class FleetSnapshotDocument(
    /** Mirror write time from the plaintext envelope (the staleness signal). */
    val updatedAtEpoch: Long?,
    /** Snapshot generation time on the Mac, from the plaintext envelope. */
    val generatedAtEpoch: Long?,
    /** The opened snapshot; null when the seal or payload could not be read. */
    val snapshot: FleetSnapshot?,
)

/** What the fleet screen renders. Every state is explicit — no blank screens. */
sealed interface FleetUiState {
    /** Nothing has been delivered yet. */
    object Loading : FleetUiState

    /** A fresh snapshot is on hand. */
    data class Ready(val snapshot: FleetSnapshot, val updatedAtEpoch: Long) : FleetUiState

    /** A fresh snapshot arrived but carries no agent rows at all. */
    data class Empty(val updatedAtEpoch: Long) : FleetUiState

    /**
     * The Mac has not written recently (or ever): the doc is missing, or its
     * `updatedAt` fell beyond the staleness threshold. [lastUpdatedAtEpoch]
     * is the last known write, when one exists, so the screen can say how far
     * behind the mirror is instead of pretending nothing was ever synced.
     */
    data class MacOffline(val lastUpdatedAtEpoch: Long?) : FleetUiState
}

/** Floor for the offline threshold — a dead publisher pref must not flap the UI. */
private const val MIN_OFFLINE_THRESHOLD_MILLIS = 15L * 60L * 1000L

/** How many missed publish cadences count as the Mac being offline. */
private const val OFFLINE_CADENCE_MULTIPLIER_MILLIS = 3L * 1000L

/** Mirror writes older than 3× the snapshot cadence (min 15 minutes) are offline. */
fun fleetOfflineThresholdMillis(cadenceSeconds: Int?): Long {
    val cadence = (cadenceSeconds ?: 0).coerceAtLeast(0) * OFFLINE_CADENCE_MULTIPLIER_MILLIS
    return maxOf(cadence, MIN_OFFLINE_THRESHOLD_MILLIS)
}

/**
 * Derives what the screen shows from the latest delivered document.
 *
 * - No delivery yet → [FleetUiState.Loading].
 * - Missing doc, missing `updatedAt`, or an unopenable payload →
 *   [FleetUiState.MacOffline] (there is no current truth to render).
 * - `updatedAt` beyond the threshold → [FleetUiState.MacOffline] with the last
 *   write time, regardless of how healthy the stale payload claims to be.
 * - Otherwise [FleetUiState.Ready] (or [FleetUiState.Empty] with no rows).
 */
fun deriveFleetUiState(hasLoadedOnce: Boolean, document: FleetSnapshotDocument?, nowEpoch: Long): FleetUiState {
    if (!hasLoadedOnce) return FleetUiState.Loading
    val updatedAt = document?.updatedAtEpoch ?: return FleetUiState.MacOffline(document?.updatedAtEpoch)
    val snapshot = document.snapshot ?: return FleetUiState.MacOffline(updatedAt)
    if (nowEpoch - updatedAt > fleetOfflineThresholdMillis(snapshot.cadenceSeconds)) {
        return FleetUiState.MacOffline(updatedAt)
    }
    if (snapshot.agents.isEmpty()) return FleetUiState.Empty(updatedAt)
    return FleetUiState.Ready(snapshot = snapshot, updatedAtEpoch = updatedAt)
}
