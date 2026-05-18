package com.openburnbar.data.missions

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

// MARK: - Mission Group Observer (Android parity, Hermes Square §6.4)
//
// Listens to `users/{uid}/mission_groups/{id}` and observes each child
// mission. Surfaces a `MissionGroupSnapshot` with rolled-up live /
// terminal / awaiting-approval counts so the fan-out card can render
// "2 of 3 done" without recomputing on every render.

data class MissionGroupSnapshot(
    val group: MissionGroup?,
    val childSnapshots: Map<String, CLIAgentMissionSnapshot> = emptyMap(),
    val inlineError: String? = null,
) {
    val derivedPhase: String?
        get() {
            val current = group?.phase ?: return null
            val statuses = group.childMissionIDs.mapNotNull { childSnapshots[it]?.status }
            if (statuses.isEmpty()) return current
            if (statuses.all { it == "completed" }) return "completed"
            if (statuses.any { it == "failed" || it == "agent_launch_failed" }) return "failed"
            if (statuses.any { it == "waiting_for_approval" }) return "awaiting_approval"
            if (statuses.any { it == "running" }) return "running"
            return current
        }

    data class Tally(val live: Int, val terminal: Int, val awaitingApproval: Int)

    val childPhaseTally: Tally
        get() {
            var live = 0; var terminal = 0; var awaiting = 0
            for (snap in childSnapshots.values) {
                when {
                    snap.isTerminal -> terminal += 1
                    snap.isWaitingForApproval -> { awaiting += 1; live += 1 }
                    else -> live += 1
                }
            }
            return Tally(live, terminal, awaiting)
        }
}

class MissionGroupObserver(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val dispatcher: CLIAgentMissionDispatcher = CLIAgentMissionDispatcher(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val _snapshot = MutableStateFlow(MissionGroupSnapshot(group = null))
    val snapshot: StateFlow<MissionGroupSnapshot> = _snapshot.asStateFlow()

    private var groupRegistration: ListenerRegistration? = null
    private val childJobs = ConcurrentHashMap<String, Job>()

    fun start(groupID: String) {
        stop()
        val uid = auth.currentUser?.uid ?: run {
            _snapshot.value = MissionGroupSnapshot(group = null, inlineError = "Sign in to track mission groups.")
            return
        }
        groupRegistration = firestore.collection("users").document(uid)
            .collection("mission_groups").document(groupID)
            .addSnapshotListener { snap, error ->
                if (error != null) {
                    _snapshot.value = _snapshot.value.copy(inlineError = error.localizedMessage)
                    return@addSnapshotListener
                }
                val data = snap?.data ?: return@addSnapshotListener
                val group = data.toMissionGroupOrNull(documentID = snap.id) ?: return@addSnapshotListener
                _snapshot.value = _snapshot.value.copy(group = group, inlineError = null)
                ensureChildObservations(group)
            }
    }

    fun stop() {
        groupRegistration?.remove(); groupRegistration = null
        childJobs.values.forEach { it.cancel() }
        childJobs.clear()
        _snapshot.value = MissionGroupSnapshot(group = null)
    }

    private fun ensureChildObservations(group: MissionGroup) {
        for (child in group.childMissionIDs) {
            if (childJobs.containsKey(child)) continue
            val job = scope.launch {
                try {
                    dispatcher.observe(child).collect { snap ->
                        val updated = _snapshot.value.childSnapshots + (child to snap)
                        _snapshot.value = _snapshot.value.copy(childSnapshots = updated)
                    }
                } catch (_: Throwable) {
                    // tolerated — keep observing other children
                }
            }
            childJobs[child] = job
        }
    }
}

private fun Map<String, Any?>.toMissionGroupOrNull(documentID: String): MissionGroup? {
    val id = (this["id"] as? String) ?: documentID
    val title = this["title"] as? String ?: return null
    val prompt = this["prompt"] as? String ?: ""
    val missionKind = this["missionKind"] as? String ?: "diligence"
    val children = (this["childMissionIDs"] as? List<*>)?.mapNotNull { it as? String } ?: return null
    val runtimes = (this["runtimeTokens"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
    return MissionGroup(
        id = id,
        title = title,
        prompt = prompt,
        missionKind = missionKind,
        targetProject = (this["targetProject"] as? String)?.takeIf { it.isNotBlank() },
        childMissionIDs = children,
        runtimeTokens = runtimes,
        parallelismLimit = (this["parallelismLimit"] as? Number)?.toInt() ?: children.size,
        mergeStrategy = this["mergeStrategy"] as? String ?: "pick_one",
        phase = this["phase"] as? String ?: "queued",
        winnerMissionID = (this["winnerMissionID"] as? String)?.takeIf { it.isNotBlank() },
        createdAtEpoch = parseIsoEpoch(this["createdAt"]) ?: System.currentTimeMillis(),
        updatedAtEpoch = parseIsoEpoch(this["updatedAt"]) ?: System.currentTimeMillis(),
    )
}

private fun parseIsoEpoch(raw: Any?): Long? = when (raw) {
    is String -> runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
    is Number -> raw.toLong()
    else -> null
}
