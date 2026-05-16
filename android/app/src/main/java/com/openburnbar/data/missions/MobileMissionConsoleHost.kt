package com.openburnbar.data.missions

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.DispatchException
import com.openburnbar.data.assistants.toMissionSnapshotOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

// MARK: - Mobile Mission Console Host (Android parity)
//
// Bridges the iOS `MobileMissionConsoleHost` to Android: listens to
// `users/{uid}/cli_agent_mission_requests`, exposes a `StateFlow` of
// active missions + approval asks, and wraps the dispatcher + approval
// responder. Lives for the app's lifetime — same shape as the iOS host.

class MobileMissionConsoleHost private constructor(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val dispatcher: CLIAgentMissionDispatcher = CLIAgentMissionDispatcher(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val _snapshot = MutableStateFlow(MissionConsoleSnapshot.EMPTY)
    val snapshot: StateFlow<MissionConsoleSnapshot> = _snapshot.asStateFlow()

    private val _inlineError = MutableStateFlow<String?>(null)
    val inlineError: StateFlow<String?> = _inlineError.asStateFlow()

    private val _isDispatching = MutableStateFlow(false)
    val isDispatching: StateFlow<Boolean> = _isDispatching.asStateFlow()

    private var listListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private val perMissionObservers = ConcurrentHashMap<String, Job>()
    private val observedMissions = ConcurrentHashMap<String, CLIAgentMissionSnapshot>()
    @Volatile private var observedOrder: List<String> = emptyList()

    fun start() {
        if (authListener != null) return
        val listener = FirebaseAuth.AuthStateListener { firebase ->
            restartListListener(firebase.currentUser?.uid)
        }
        authListener = listener
        auth.addAuthStateListener(listener)
        restartListListener(auth.currentUser?.uid)
    }

    fun stop() {
        listListener?.remove(); listListener = null
        perMissionObservers.values.forEach { it.cancel() }
        perMissionObservers.clear()
        observedMissions.clear()
        observedOrder = emptyList()
        authListener?.let { auth.removeAuthStateListener(it) }
        authListener = null
        scope.coroutineContext[Job]?.cancelChildren()
    }

    suspend fun dispatch(
        title: String,
        prompt: String,
        missionKind: String,
        runtimeID: String = "auto",
        targetProject: String? = null,
        commandsAllowed: Boolean = false,
        fileEditsAllowed: Boolean = false,
    ): String? {
        _isDispatching.value = true
        return try {
            val id = dispatcher.dispatch(
                title = title.trim().ifBlank { "Mission · $missionKind" },
                prompt = prompt,
                missionKind = missionKind,
                requestedRuntime = runtimeID,
                targetProject = targetProject,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
            )
            beginObservingIfNeeded(id)
            id
        } catch (e: DispatchException) {
            _inlineError.value = e.message
            null
        } catch (e: Exception) {
            _inlineError.value = e.localizedMessage ?: "Dispatch failed."
            null
        } finally {
            _isDispatching.value = false
        }
    }

    suspend fun respond(ask: ApprovalAsk, approve: Boolean) {
        try {
            dispatcher.respondToApproval(requestID = ask.missionID, approve = approve)
        } catch (e: Exception) {
            _inlineError.value = e.localizedMessage ?: "Approval response failed."
        }
    }

    fun clearInlineError() { _inlineError.value = null }

    private fun restartListListener(uid: String?) {
        listListener?.remove(); listListener = null
        perMissionObservers.values.forEach { it.cancel() }
        perMissionObservers.clear()
        observedMissions.clear()
        observedOrder = emptyList()
        if (uid == null) {
            rebuildSnapshot()
            return
        }
        listListener = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .limit(12)
            .addSnapshotListener { snap, error ->
                if (error != null) {
                    _inlineError.value = error.localizedMessage
                    return@addSnapshotListener
                }
                val missions = snap?.documents.orEmpty().mapNotNull { doc ->
                    doc.toMissionSnapshotOrNull()
                }
                absorb(missions)
            }
    }

    private fun absorb(missions: List<CLIAgentMissionSnapshot>) {
        observedOrder = missions.map { it.id }
        for (mission in missions) {
            observedMissions[mission.id] = mission
            beginObservingIfNeeded(mission.id)
        }
        val newIDs = missions.map { it.id }.toSet()
        for (id in perMissionObservers.keys.toList()) {
            if (id !in newIDs) {
                perMissionObservers.remove(id)?.cancel()
                observedMissions.remove(id)
            }
        }
        rebuildSnapshot()
    }

    private fun beginObservingIfNeeded(missionID: String) {
        if (perMissionObservers.containsKey(missionID)) return
        val job = scope.launch {
            try {
                dispatcher.observe(missionID).collect { snapshot ->
                    observedMissions[snapshot.id] = snapshot
                    if (snapshot.id !in observedOrder) {
                        observedOrder = listOf(snapshot.id) + observedOrder
                    }
                    rebuildSnapshot()
                }
            } catch (_: Throwable) {
                // listener torn down — auth change or sign-out; ignore.
            }
        }
        perMissionObservers[missionID] = job
    }

    private fun rebuildSnapshot() {
        val orderedMissions = observedOrder.mapNotNull { observedMissions[it] }
        val macOnline = orderedMissions.any { snap ->
            (snap.selectedRuntime ?: "").isNotBlank() || snap.status !in setOf("pending", "queued")
        }
        val activeTiles = orderedMissions
            .filter { !it.isTerminal && !(it.displayStatus == "mac_offline" && macOnline) }
            .map { it.toActiveMission() }
        val approvalAsks = orderedMissions.mapNotNull { it.toApprovalAskOrNull() }
        val ticker = orderedMissions
            .flatMap { mission ->
                mission.events.takeLast(6).map { ev ->
                    TickerEntry(
                        id = "${mission.id}-${ev.sequence}",
                        timestampEpoch = runCatching { Instant.parse(ev.timestamp).toEpochMilli() }.getOrDefault(System.currentTimeMillis()),
                        kind = when (ev.kind) {
                            "tool_call" -> TickerEntry.Kind.TOOL_CALL
                            "tool_result" -> TickerEntry.Kind.TOOL_RESULT
                            "llm_response" -> TickerEntry.Kind.LLM_RESPONSE
                            "final_answer" -> TickerEntry.Kind.FINAL_ANSWER
                            "changed_file" -> TickerEntry.Kind.CHANGED_FILE
                            "artifact" -> TickerEntry.Kind.ARTIFACT
                            "error" -> TickerEntry.Kind.ERROR
                            "approval_request" -> TickerEntry.Kind.APPROVAL
                            else -> TickerEntry.Kind.STATUS
                        },
                        phase = ev.phase,
                        title = ev.title,
                        message = ev.fullMessage ?: ev.message,
                        toolName = ev.toolName,
                        pathDetail = ev.changedFilePath ?: ev.artifactPath,
                        missionID = mission.id,
                        runtimeID = runtimeIDGuess(mission.selectedRuntime ?: mission.requestedRuntime),
                        isError = ev.isError,
                    )
                }
            }
            .sortedByDescending { it.timestampEpoch }
            .take(16)
        val knownProjects = orderedMissions
            .mapNotNull { snap ->
                snap.toProjectField()
            }
            .distinct()
            .take(24)
        val recentProjects = knownProjects.take(12)
        _snapshot.value = MissionConsoleSnapshot(
            activeMissions = activeTiles,
            approvalQueue = approvalAsks,
            groups = emptyList(),
            recentTicker = ticker,
            knownProjects = knownProjects,
            recentProjects = recentProjects,
            openMissions = activeTiles.count { it.phase.isLive },
            queuedMissions = activeTiles.count { it.phase == ActiveMission.Phase.QUEUED },
            blockedMissions = activeTiles.count { it.phase == ActiveMission.Phase.FAILED || it.phase == ActiveMission.Phase.BLOCKED },
            daemonState = when {
                orderedMissions.any { it.displayStatus == "mac_offline" } && !macOnline -> DaemonState.MAC_OFFLINE
                macOnline -> DaemonState.LIVE
                else -> DaemonState.UNKNOWN
            },
        )
    }

    companion object {
        @Volatile private var instance: MobileMissionConsoleHost? = null

        fun shared(): MobileMissionConsoleHost =
            instance ?: synchronized(this) {
                instance ?: MobileMissionConsoleHost().also { instance = it }
            }
    }
}

private fun CLIAgentMissionSnapshot.toProjectField(): String? {
    // CLIAgentMissionSnapshot doesn't carry targetProject in its Kotlin
    // shape — keep the hook here so future schema bumps land cleanly.
    return null
}
