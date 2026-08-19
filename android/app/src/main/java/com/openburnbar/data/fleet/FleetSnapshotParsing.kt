package com.openburnbar.data.fleet

import org.json.JSONArray
import org.json.JSONObject

// MARK: - Fleet snapshot JSON parsing
//
// Hand-rolled org.json reader for the sealed `BurnBarFleetSnapshot` payload.
// The wire shape is the Swift `Codable` output documented in
// `BurnBarFleetContracts.swift`; every key string below is pinned to a Swift
// `CodingKeys` case. Parsing never throws out of this file: a snapshot the
// phone cannot read at all returns null, unreadable rows inside an otherwise
// valid snapshot are dropped, and unknown enum wires degrade per the
// forward-compat notes in `FleetModels.kt`.

/**
 * Parses the sealed snapshot JSON. Returns null when the payload is not a v1
 * snapshot (unsupported `schemaVersion`, missing required top-level fields, or
 * not JSON at all).
 */
fun parseFleetSnapshot(json: String): FleetSnapshot? {
    val root = runCatching { JSONObject(json) }.getOrNull() ?: return null
    val schemaVersion = root.optInt("schemaVersion", -1)
    if (schemaVersion != FleetSnapshot.CURRENT_SCHEMA_VERSION) return null
    val generatedAt = fleetEpochMillis(root.optString("generatedAt", "")) ?: return null
    val machine = parseFleetMachine(root.optJSONObject("machine")) ?: return null
    return FleetSnapshot(
        schemaVersion = schemaVersion,
        generatedAtEpoch = generatedAt,
        cadenceSeconds = root.optInt("cadenceSeconds", 0),
        machine = machine,
        agents = mapArray(root.optJSONArray("agents"), ::parseFleetAgent),
        repos = mapArray(root.optJSONArray("repos"), ::parseFleetRepoGroup),
        runningCount = root.optInt("runningCount", 0),
        countsByAgent = parseCountsByAgent(root.optJSONObject("countsByAgent")),
        orchestrator = parseFleetOrchestrator(root.optJSONObject("orchestrator")),
        probeHealth = mapArray(root.optJSONArray("probeHealth"), ::parseFleetProbeHealth),
        persistenceHealth = parseFleetPersistenceHealth(root.optJSONObject("persistenceHealth")),
    )
}

/** ISO-8601 UTC string → epoch millis; anything else is absent, never zero. */
internal fun fleetEpochMillis(raw: String?): Long? {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    return runCatching { java.time.Instant.parse(trimmed).toEpochMilli() }.getOrNull()
}

private fun <T : Any> mapArray(array: JSONArray?, parse: (JSONObject) -> T?): List<T> {
    if (array == null) return emptyList()
    return (0 until array.length()).mapNotNull { index ->
        array.optJSONObject(index)?.let(parse)
    }
}

private fun JSONObject.optionalString(key: String): String? = if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotEmpty() } else null

private fun JSONObject.optionalDouble(key: String): Double? = if (has(key) && !isNull(key)) optDouble(key).takeIf { it.isFinite() } else null

private fun JSONObject.optionalLong(key: String): Long? = if (has(key) && !isNull(key)) optLong(key) else null

private fun parseFleetAgent(obj: JSONObject): FleetAgent? {
    val id = obj.optionalString("id") ?: return null
    val displayName = obj.optionalString("displayName") ?: return null
    return FleetAgent(
        id = id,
        displayName = displayName,
        status = FleetAgentStatus.fromWire(obj.optionalString("status")),
        confidence = FleetConfidence.fromWire(obj.optionalString("confidence")),
        currentTask = obj.optionalString("currentTask"),
        projectName = obj.optionalString("projectName"),
        model = obj.optionalString("model"),
        lastActivityAtEpoch = fleetEpochMillis(obj.optionalString("lastActivityAt")),
        process = obj.optJSONObject("process")?.let(::parseFleetProcess),
        signals = mapArray(obj.optJSONArray("signals"), ::parseFleetSignal),
        note = obj.optionalString("note"),
    )
}

private fun parseFleetProcess(obj: JSONObject): FleetProcessInfo? {
    if (!obj.has("pid")) return null
    return FleetProcessInfo(
        pid = obj.optInt("pid"),
        cpuPercent = obj.optionalDouble("cpuPercent"),
        memoryBytes = obj.optionalLong("memoryBytes"),
        startedAtEpoch = fleetEpochMillis(obj.optionalString("startedAt")),
    )
}

private fun parseFleetSignal(obj: JSONObject): FleetSignalSource? {
    val kind = obj.optionalString("kind") ?: return null
    val path = obj.optionalString("path") ?: return null
    return FleetSignalSource(kind = kind, path = path, detail = obj.optionalString("detail"))
}

private fun parseFleetMachine(obj: JSONObject?): FleetMachineStatus? {
    if (obj == null || !obj.has("memoryTotalBytes")) return null
    return FleetMachineStatus(
        cpuPercent = obj.optionalDouble("cpuPercent"),
        memoryUsedBytes = obj.optionalLong("memoryUsedBytes"),
        memoryTotalBytes = obj.optLong("memoryTotalBytes"),
        loadAverage = parseLoadAverage(obj.optJSONArray("loadAverage")),
        diskFreeBytes = obj.optionalLong("diskFreeBytes"),
        thermal = parseFleetSensor(obj.optJSONObject("thermal")),
        power = parseFleetSensor(obj.optJSONObject("power")),
    )
}

private fun parseLoadAverage(array: JSONArray?): List<Double>? {
    if (array == null) return null
    return (0 until array.length()).map { array.optDouble(it) }.filter { it.isFinite() }
}

private fun parseFleetSensor(obj: JSONObject?): FleetSensorState {
    val kind = obj?.optionalString("kind")
    return when (kind) {
        "available" -> {
            val value = obj.optionalDouble("value")
            if (value != null) {
                FleetSensorState.Available(value)
            } else {
                FleetSensorState.Unavailable("available state carried no value")
            }
        }
        "unavailable" -> FleetSensorState.Unavailable(obj.optionalString("reason") ?: "no reason reported")
        null -> FleetSensorState.Unavailable("sensor state missing")
        else -> FleetSensorState.Unavailable("unrecognized sensor state '$kind'")
    }
}

private fun parseFleetRepoGroup(obj: JSONObject): FleetRepoGroup? {
    val projectName = obj.optionalString("projectName") ?: return null
    val agents = obj.optJSONArray("agents") ?: JSONArray()
    return FleetRepoGroup(
        projectName = projectName,
        agents = (0 until agents.length()).mapNotNull { agents.optString(it).takeIf(String::isNotEmpty) },
    )
}

private fun parseFleetProbeHealth(obj: JSONObject): FleetProbeHealth? {
    val agent = obj.optionalString("agent") ?: return null
    val rootPath = obj.optionalString("rootPath") ?: return null
    val checkedAt = fleetEpochMillis(obj.optionalString("checkedAt")) ?: return null
    return FleetProbeHealth(
        agent = agent,
        state = parseFleetProbeHealthState(obj.optJSONObject("state")),
        rootPath = rootPath,
        checkedAtEpoch = checkedAt,
    )
}

private fun parseFleetProbeHealthState(obj: JSONObject?): FleetProbeHealthState {
    val kind = obj?.optionalString("kind")
    return when (kind) {
        "ok" -> FleetProbeHealthState.Ok
        "degraded" -> FleetProbeHealthState.Degraded(obj.optionalString("reason") ?: "no reason reported")
        "failed" -> FleetProbeHealthState.Failed(obj.optionalString("reason") ?: "no reason reported")
        null -> FleetProbeHealthState.Degraded("probe state missing")
        else -> FleetProbeHealthState.Degraded("unrecognized probe state '$kind'")
    }
}

private fun parseFleetPersistenceHealth(obj: JSONObject?): FleetPersistenceHealth {
    val kind = obj?.optionalString("kind")
    return when (kind) {
        "ok" -> FleetPersistenceHealth.Ok
        "degraded" -> FleetPersistenceHealth.Degraded(obj.optionalString("reason") ?: "no reason reported")
        null -> FleetPersistenceHealth.Degraded("persistence state missing")
        else -> FleetPersistenceHealth.Degraded("unrecognized persistence state '$kind'")
    }
}

private fun parseFleetOrchestrator(obj: JSONObject?): FleetOrchestratorState {
    if (obj == null) {
        return FleetOrchestratorState(designation = FleetOrchestratorDesignation.Unrecognized("missing"))
    }
    return FleetOrchestratorState(
        designation = parseFleetDesignation(obj.optJSONObject("designation")),
        setAtEpoch = fleetEpochMillis(obj.optionalString("setAt")),
        pendingDirectives = obj.optInt("pendingDirectives", 0),
    )
}

private fun parseFleetDesignation(obj: JSONObject?): FleetOrchestratorDesignation {
    val kind = obj?.optionalString("kind")
    return when (kind) {
        "none" -> FleetOrchestratorDesignation.None
        "burnBarManaged" -> FleetOrchestratorDesignation.BurnBarManaged
        "agent" -> {
            val id = obj.optionalString("id")
            if (id == null) {
                FleetOrchestratorDesignation.Unrecognized("agent-without-id")
            } else {
                FleetOrchestratorDesignation.Agent(id = id, sessionRef = obj.optionalString("sessionRef"))
            }
        }
        null -> FleetOrchestratorDesignation.Unrecognized("missing")
        else -> FleetOrchestratorDesignation.Unrecognized(kind)
    }
}

private fun parseCountsByAgent(obj: JSONObject?): Map<String, Int> {
    if (obj == null) return emptyMap()
    val counts = mutableMapOf<String, Int>()
    for (key in obj.keys()) {
        counts[key] = obj.optInt(key, 0)
    }
    return counts
}
