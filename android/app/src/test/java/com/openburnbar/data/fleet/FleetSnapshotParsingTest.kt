package com.openburnbar.data.fleet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-shape tests for the hand-rolled fleet snapshot reader. The JSON below
 * is the Swift `Codable` output shape documented in
 * `OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarFleetContracts.swift`
 * (schemaVersion 1, ISO-8601 UTC dates, tagged sensor/health/designation
 * objects), so this suite is the Android side's contract pin.
 */
class FleetSnapshotParsingTest {
    private fun goldenSnapshotJson(): String = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-19T10:15:00.000Z",
          "cadenceSeconds": 30,
          "machine": {
            "cpuPercent": 41.5,
            "memoryUsedBytes": 17179869184,
            "memoryTotalBytes": 34359738368,
            "loadAverage": [3.1, 2.8, 2.5],
            "diskFreeBytes": 214748364800,
            "thermal": {"kind": "unavailable", "reason": "no cheap API"},
            "power": {"kind": "available", "value": 42.0}
          },
          "agents": [
            {
              "id": "claude-code",
              "displayName": "Claude Code",
              "status": "running",
              "confidence": "exactProcess",
              "currentTask": "fix/grdb-row-decode-correctness",
              "projectName": "BurnBar",
              "model": "claude-fable-5",
              "lastActivityAt": "2026-08-19T10:14:20.000Z",
              "process": {"pid": 4242, "cpuPercent": 85.0, "memoryBytes": 524288000, "startedAt": "2026-08-19T08:00:00.000Z"},
              "signals": [{"kind": "process-list", "path": "/proc/4242", "detail": "argv match"}],
              "note": null
            },
            {
              "id": "codex",
              "displayName": "Codex",
              "status": "idle",
              "confidence": "activeSessionFile",
              "signals": []
            },
            {
              "id": "some-future-agent",
              "displayName": "Future Agent",
              "status": "hibernating",
              "confidence": "quantumSensing",
              "signals": []
            }
          ],
          "repos": [
            {"projectName": "BurnBar", "agents": ["claude-code", "some-future-agent"]}
          ],
          "runningCount": 1,
          "countsByAgent": {"claude-code": 1, "codex": 0},
          "orchestrator": {
            "designation": {"kind": "agent", "id": "claude-code", "sessionRef": null},
            "setAt": "2026-08-12T01:01:05.000Z",
            "pendingDirectives": 2
          },
          "probeHealth": [
            {"agent": "claude-code", "state": {"kind": "ok"}, "rootPath": "/Users/x/.claude", "checkedAt": "2026-08-19T10:14:58.000Z"},
            {"agent": "codex", "state": {"kind": "degraded", "reason": "root unreadable"}, "rootPath": "/Users/x/.codex", "checkedAt": "2026-08-19T10:14:58.000Z"}
          ],
          "persistenceHealth": {"kind": "ok"}
        }
    """.trimIndent()

    @Test
    fun `parses the golden v1 snapshot with exact field names`() {
        val snapshot = parseFleetSnapshot(goldenSnapshotJson())

        assertNotNull(snapshot)
        snapshot!!
        assertEquals(1, snapshot.schemaVersion)
        assertEquals(30, snapshot.cadenceSeconds)
        assertEquals(1, snapshot.runningCount)
        assertEquals(mapOf("claude-code" to 1, "codex" to 0), snapshot.countsByAgent)

        val claude = snapshot.agents.first()
        assertEquals("claude-code", claude.id)
        assertEquals("Claude Code", claude.displayName)
        assertEquals(FleetAgentStatus.RUNNING, claude.status)
        assertEquals(FleetConfidence.EXACT_PROCESS, claude.confidence)
        assertEquals("fix/grdb-row-decode-correctness", claude.currentTask)
        assertEquals("BurnBar", claude.projectName)
        assertEquals(4242, claude.process?.pid)
        assertEquals("process-list", claude.signals.first().kind)
        assertNull(claude.note)

        assertEquals(FleetSensorState.Unavailable("no cheap API"), snapshot.machine.thermal)
        assertEquals(FleetSensorState.Available(42.0), snapshot.machine.power)
        assertEquals(listOf(3.1, 2.8, 2.5), snapshot.machine.loadAverage)

        assertEquals(
            FleetOrchestratorDesignation.Agent(id = "claude-code", sessionRef = null),
            snapshot.orchestrator.designation,
        )
        assertEquals(2, snapshot.orchestrator.pendingDirectives)

        assertEquals(FleetProbeHealthState.Ok, snapshot.probeHealth[0].state)
        assertEquals(FleetProbeHealthState.Degraded("root unreadable"), snapshot.probeHealth[1].state)
        assertEquals(FleetPersistenceHealth.Ok, snapshot.persistenceHealth)
    }

    @Test
    fun `unknown agent ids ride through losslessly`() {
        val snapshot = parseFleetSnapshot(goldenSnapshotJson())!!

        assertEquals("some-future-agent", snapshot.agents[2].id)
        assertEquals("Future Agent", snapshot.agents[2].displayName)
        assertTrue(snapshot.repos[0].agents.contains("some-future-agent"))
    }

    @Test
    fun `unknown enum wires degrade instead of crashing`() {
        val snapshot = parseFleetSnapshot(goldenSnapshotJson())!!
        val future = snapshot.agents[2]

        // Swift throws typed errors here; the phone reads snapshots written by
        // NEWER Macs, so it degrades to the weakest honest claim instead.
        assertEquals(FleetAgentStatus.UNKNOWN, future.status)
        assertEquals(FleetConfidence.UNSUPPORTED, future.confidence)
    }

    @Test
    fun `unknown tagged state kinds degrade to typed unavailability`() {
        val json = goldenSnapshotJson()
            .replace("""{"kind": "unavailable", "reason": "no cheap API"}""", """{"kind": "psychic"}""")
            .replace(""""persistenceHealth": {"kind": "ok"}""", """"persistenceHealth": {"kind": "shrugging"}""")

        val snapshot = parseFleetSnapshot(json)!!

        assertEquals(FleetSensorState.Unavailable("unrecognized sensor state 'psychic'"), snapshot.machine.thermal)
        assertEquals(
            FleetPersistenceHealth.Degraded("unrecognized persistence state 'shrugging'"),
            snapshot.persistenceHealth,
        )
    }

    @Test
    fun `a snapshot from the future is refused whole`() {
        val json = goldenSnapshotJson().replace("\"schemaVersion\": 1", "\"schemaVersion\": 2")

        assertNull(parseFleetSnapshot(json))
    }

    @Test
    fun `garbage and missing required fields return null`() {
        assertNull(parseFleetSnapshot("not json"))
        assertNull(parseFleetSnapshot("{}"))
        assertNull(parseFleetSnapshot("""{"schemaVersion": 1, "generatedAt": "not-a-date"}"""))
    }

    @Test
    fun `unreadable agent rows are dropped without sinking the snapshot`() {
        // Stripping the codex row's id makes that one row unreadable.
        val json = goldenSnapshotJson().replace(""""id": "codex",""", "")

        val snapshot = parseFleetSnapshot(json)!!

        assertEquals(listOf("claude-code", "some-future-agent"), snapshot.agents.map { it.id })
    }
}
