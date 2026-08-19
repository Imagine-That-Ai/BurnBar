package com.openburnbar.data.fleet

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * State-derivation tests for the fleet store's pure parts: the
 * loading / ready / empty / mac-offline decision and the staleness threshold
 * (3× cadence, floored at 15 minutes).
 */
class FleetStorePartsTest {
    private val now = 1_755_600_000_000L

    private fun snapshot(cadenceSeconds: Int = 30, agents: List<FleetAgent> = listOf(agent())): FleetSnapshot = FleetSnapshot(
        schemaVersion = 1,
        generatedAtEpoch = now - 5_000,
        cadenceSeconds = cadenceSeconds,
        machine = FleetMachineStatus(
            memoryTotalBytes = 34_359_738_368L,
            thermal = FleetSensorState.Unavailable("n/a"),
            power = FleetSensorState.Unavailable("n/a"),
        ),
        agents = agents,
        repos = emptyList(),
        runningCount = agents.count { it.status == FleetAgentStatus.RUNNING },
        countsByAgent = emptyMap(),
        orchestrator = FleetOrchestratorState(designation = FleetOrchestratorDesignation.None),
        probeHealth = emptyList(),
        persistenceHealth = FleetPersistenceHealth.Ok,
    )

    private fun agent(): FleetAgent = FleetAgent(
        id = "claude-code",
        displayName = "Claude Code",
        status = FleetAgentStatus.RUNNING,
        confidence = FleetConfidence.EXACT_PROCESS,
    )

    // ── Threshold ──

    @Test
    fun `the offline threshold is three cadences floored at fifteen minutes`() {
        // 30s cadence → the 15-minute floor wins.
        assertEquals(15L * 60L * 1000L, fleetOfflineThresholdMillis(30))
        // 10-minute cadence → 3× cadence wins.
        assertEquals(30L * 60L * 1000L, fleetOfflineThresholdMillis(600))
        // Absent/degenerate cadences never collapse the threshold to zero.
        assertEquals(15L * 60L * 1000L, fleetOfflineThresholdMillis(null))
        assertEquals(15L * 60L * 1000L, fleetOfflineThresholdMillis(-5))
    }

    // ── Derivation ──

    @Test
    fun `nothing delivered yet is loading`() {
        assertEquals(FleetUiState.Loading, deriveFleetUiState(hasLoadedOnce = false, document = null, nowEpoch = now))
    }

    @Test
    fun `a missing document is mac-offline with no last write`() {
        assertEquals(
            FleetUiState.MacOffline(null),
            deriveFleetUiState(hasLoadedOnce = true, document = null, nowEpoch = now),
        )
    }

    @Test
    fun `an unopenable payload is mac-offline with the last write kept`() {
        val document = FleetSnapshotDocument(updatedAtEpoch = now - 1_000, generatedAtEpoch = null, snapshot = null)

        assertEquals(
            FleetUiState.MacOffline(now - 1_000),
            deriveFleetUiState(hasLoadedOnce = true, document = document, nowEpoch = now),
        )
    }

    @Test
    fun `a fresh snapshot with rows is ready`() {
        val snap = snapshot()
        val document = FleetSnapshotDocument(updatedAtEpoch = now - 1_000, generatedAtEpoch = now - 5_000, snapshot = snap)

        assertEquals(
            FleetUiState.Ready(snapshot = snap, updatedAtEpoch = now - 1_000),
            deriveFleetUiState(hasLoadedOnce = true, document = document, nowEpoch = now),
        )
    }

    @Test
    fun `a fresh snapshot with zero rows is empty`() {
        val document = FleetSnapshotDocument(
            updatedAtEpoch = now - 1_000,
            generatedAtEpoch = now - 5_000,
            snapshot = snapshot(agents = emptyList()),
        )

        assertEquals(
            FleetUiState.Empty(now - 1_000),
            deriveFleetUiState(hasLoadedOnce = true, document = document, nowEpoch = now),
        )
    }

    @Test
    fun `a stale write is mac-offline no matter how healthy its payload claims to be`() {
        val stale = now - 16L * 60L * 1000L
        val document = FleetSnapshotDocument(updatedAtEpoch = stale, generatedAtEpoch = stale, snapshot = snapshot())

        assertEquals(
            FleetUiState.MacOffline(stale),
            deriveFleetUiState(hasLoadedOnce = true, document = document, nowEpoch = now),
        )
    }

    @Test
    fun `a long publish cadence extends the offline window`() {
        // 16 minutes old is offline at a 30s cadence but current at a
        // 10-minute cadence (threshold 30 minutes).
        val at = now - 16L * 60L * 1000L
        val slowCadence = snapshot(cadenceSeconds = 600)
        val document = FleetSnapshotDocument(updatedAtEpoch = at, generatedAtEpoch = at, snapshot = slowCadence)

        assertEquals(
            FleetUiState.Ready(snapshot = slowCadence, updatedAtEpoch = at),
            deriveFleetUiState(hasLoadedOnce = true, document = document, nowEpoch = now),
        )
    }
}
