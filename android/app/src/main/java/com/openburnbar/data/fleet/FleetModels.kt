package com.openburnbar.data.fleet

// MARK: - Fleet snapshot mirror models (Android parity)
//
// Kotlin mirrors of the Swift fleet contracts in
// `OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarFleetContracts.swift`.
// Field names are pinned to the Swift `CodingKeys` so the sealed snapshot JSON
// the Mac publishes reads back verbatim; dates are ISO-8601 UTC strings on the
// wire and epoch millis in memory.
//
// Forward compatibility differs deliberately from Swift: the Mac decoder
// throws a typed error on an unknown enum wire string because the daemon and
// the Mac app ship together, but the phone reads snapshots written by NEWER
// Macs. A phone must not blank the whole dashboard over one new enum value, so
// unknown wires degrade to the weakest honest claim (`UNKNOWN` status,
// `UNSUPPORTED` confidence, typed `Unrecognized`/`unavailable` states) and
// unknown agent ids ride through losslessly as raw strings.

/** Wire status of a fleet agent row (`running` / `idle` / `stale` / `unknown`). */
enum class FleetAgentStatus(val wire: String) {
    RUNNING("running"),
    IDLE("idle"),
    STALE("stale"),
    UNKNOWN("unknown"),
    ;

    companion object {
        /** Unknown wires degrade to [UNKNOWN] — "probe could not determine". */
        fun fromWire(raw: String?): FleetAgentStatus = entries.firstOrNull { it.wire == raw } ?: UNKNOWN
    }
}

/** Liveness confidence, ordered strongest to weakest on the Mac. */
enum class FleetConfidence(val wire: String) {
    EXACT_PROCESS("exactProcess"),
    ACTIVE_SESSION_FILE("activeSessionFile"),
    LOG_HEARTBEAT("logHeartbeat"),
    ESTIMATED("estimated"),
    UNSUPPORTED("unsupported"),
    ;

    companion object {
        /** Unknown wires degrade to [UNSUPPORTED] — "no live signal we understand". */
        fun fromWire(raw: String?): FleetConfidence = entries.firstOrNull { it.wire == raw } ?: UNSUPPORTED
    }
}

/** One piece of probe evidence behind an agent row. */
data class FleetSignalSource(
    val kind: String,
    val path: String,
    val detail: String? = null,
)

/** Process-level detail, present only when exact-process confidence permits. */
data class FleetProcessInfo(
    val pid: Int,
    val cpuPercent: Double? = null,
    val memoryBytes: Long? = null,
    val startedAtEpoch: Long? = null,
)

/**
 * One agent row. [id] stays the raw wire string (`claude-code`, `codex`, …)
 * so ids outside the declared roster survive losslessly; [displayName] comes
 * from the payload, never invented here.
 */
data class FleetAgent(
    val id: String,
    val displayName: String,
    val status: FleetAgentStatus,
    val confidence: FleetConfidence,
    val currentTask: String? = null,
    val projectName: String? = null,
    val model: String? = null,
    val lastActivityAtEpoch: Long? = null,
    val process: FleetProcessInfo? = null,
    val signals: List<FleetSignalSource> = emptyList(),
    val note: String? = null,
)

/** Honest sensor reading: a real value or a typed unavailability with reason. */
sealed interface FleetSensorState {
    data class Available(val value: Double) : FleetSensorState

    data class Unavailable(val reason: String) : FleetSensorState
}

/** Machine status block; absent numerics stay absent — never fabricated. */
data class FleetMachineStatus(
    val cpuPercent: Double? = null,
    val memoryUsedBytes: Long? = null,
    val memoryTotalBytes: Long,
    val loadAverage: List<Double>? = null,
    val diskFreeBytes: Long? = null,
    val thermal: FleetSensorState,
    val power: FleetSensorState,
)

/** Derived per-repo grouping of agent ids. */
data class FleetRepoGroup(
    val projectName: String,
    val agents: List<String>,
)

/** Typed per-agent probe health. */
sealed interface FleetProbeHealthState {
    object Ok : FleetProbeHealthState

    data class Degraded(val reason: String) : FleetProbeHealthState

    data class Failed(val reason: String) : FleetProbeHealthState
}

data class FleetProbeHealth(
    val agent: String,
    val state: FleetProbeHealthState,
    val rootPath: String,
    val checkedAtEpoch: Long,
)

/** Daemon persistence health (SQLite store + well-known-file writer). */
sealed interface FleetPersistenceHealth {
    object Ok : FleetPersistenceHealth

    data class Degraded(val reason: String) : FleetPersistenceHealth
}

/** Who is designated to orchestrate the fleet. */
sealed interface FleetOrchestratorDesignation {
    object None : FleetOrchestratorDesignation

    object BurnBarManaged : FleetOrchestratorDesignation

    data class Agent(val id: String, val sessionRef: String? = null) : FleetOrchestratorDesignation

    /** A designation kind this build does not know; kept typed, never guessed at. */
    data class Unrecognized(val kind: String) : FleetOrchestratorDesignation
}

data class FleetOrchestratorState(
    val designation: FleetOrchestratorDesignation,
    val setAtEpoch: Long? = null,
    val pendingDirectives: Int = 0,
)

/** The complete fleet snapshot, as sealed and mirrored by the Mac. */
data class FleetSnapshot(
    val schemaVersion: Int,
    val generatedAtEpoch: Long,
    val cadenceSeconds: Int,
    val machine: FleetMachineStatus,
    val agents: List<FleetAgent>,
    val repos: List<FleetRepoGroup>,
    val runningCount: Int,
    val countsByAgent: Map<String, Int>,
    val orchestrator: FleetOrchestratorState,
    val probeHealth: List<FleetProbeHealth>,
    val persistenceHealth: FleetPersistenceHealth,
) {
    companion object {
        /** Bumped alongside the Swift contract; newer snapshots are refused. */
        const val CURRENT_SCHEMA_VERSION = 1
    }
}
