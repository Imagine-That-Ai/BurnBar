package com.openburnbar.data.missions

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.DispatchException
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.assistants.toMissionSnapshotOrNull
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import java.lang.IllegalStateException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

private const val VAL_12 = 12

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
    private val dismissedTerminalIDs = ConcurrentHashMap.newKeySet<String>()

    fun start() {
        if (authListener != null) return
        val listener =
            FirebaseAuth.AuthStateListener { firebase ->
                restartListListener(firebase.currentUser?.uid)
            }
        authListener = listener
        auth.addAuthStateListener(listener)
        restartListListener(auth.currentUser?.uid)
    }

    fun stop() {
        listListener?.remove()
        listListener = null
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
        sourceSkillID: String? = null,
        sourceSurface: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        parentHermesThreadID: String? = null,
    ): String? {
        _isDispatching.value = true
        return try {
            val id =
                dispatcher.dispatch(
                    title = title.trim().ifBlank { "Mission · $missionKind" },
                    prompt = prompt,
                    missionKind = missionKind,
                    requestedRuntime = runtimeID,
                    targetProject = targetProject,
                    commandsAllowed = commandsAllowed,
                    fileEditsAllowed = fileEditsAllowed,
                    sourceSkillID = sourceSkillID,
                    sourceSurface = sourceSurface,
                    deliveryMode = deliveryMode,
                    parentHermesThreadID = parentHermesThreadID,
                )
            beginObservingIfNeeded(id)
            id
        } catch (e: DispatchException) {
            _inlineError.value = e.message
            null
        } catch (e: IllegalStateException) {
            _inlineError.value = e.localizedMessage ?: "Dispatch failed."
            null
        } finally {
            _isDispatching.value = false
        }
    }

    suspend fun respond(ask: ApprovalAsk, approve: Boolean) {
        try {
            dispatcher.respondToApproval(requestID = ask.missionID, approve = approve)
        } catch (e: IllegalStateException) {
            _inlineError.value = e.localizedMessage ?: "Approval response failed."
        }
    }

    suspend fun cancelMission(id: String) {
        try {
            dispatcher.cancelMission(id)
        } catch (e: IllegalStateException) {
            _inlineError.value = e.localizedMessage ?: "Cancellation failed."
        }
    }

    fun dismissMission(id: String) {
        dismissedTerminalIDs.add(id)
        rebuildSnapshot()
    }

    fun clearInlineError() {
        _inlineError.value = null
    }

    private fun restartListListener(uid: String?) {
        listListener?.remove()
        listListener = null
        perMissionObservers.values.forEach { it.cancel() }
        perMissionObservers.clear()
        observedMissions.clear()
        observedOrder = emptyList()
        dismissedTerminalIDs.clear()
        if (uid == null) {
            rebuildSnapshot()
            return
        }
        scope.launch {
            val vaultKey = runCatching { AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData }.getOrNull()
            listListener =
                firestore.collection("users").document(uid)
                    .collection("cli_agent_mission_requests")
                    .orderBy("createdAt", Query.Direction.DESCENDING)
                    .limit(VAL_12.toLong())
                    .addSnapshotListener { snap, error ->
                        if (error != null) {
                            _inlineError.value = error.localizedMessage
                            return@addSnapshotListener
                        }
                        val missions =
                            snap?.documents.orEmpty().mapNotNull { doc ->
                                doc.toMissionSnapshotOrNull(vaultKey)
                            }
                        absorb(missions)
                    }
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
        val job =
            scope.launch {
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
        val orderedMissions =
            observedOrder.mapNotNull { observedMissions[it] }
                .filter { it.id !in dismissedTerminalIDs }
        val parts = buildMissionConsoleSnapshotParts(orderedMissions, ::runtimeIDGuess)
        _snapshot.value =
            MissionConsoleSnapshot(
                activeMissions = parts.activeTiles,
                approvalQueue = parts.approvalAsks,
                groups = emptyList(),
                recentTicker = parts.ticker,
                knownProjects = parts.knownProjects,
                recentProjects = parts.knownProjects.take(VAL_12),
                openMissions = parts.activeTiles.count { it.phase.isLive },
                queuedMissions = parts.activeTiles.count { it.phase == ActiveMission.Phase.QUEUED },
                blockedMissions = parts.activeTiles.count { it.phase == ActiveMission.Phase.FAILED || it.phase == ActiveMission.Phase.BLOCKED },
                daemonState = parts.daemonState,
            )
    }

    companion object {
        @Volatile private var instance: MobileMissionConsoleHost? = null

        fun shared(): MobileMissionConsoleHost = instance ?: synchronized(this) {
            instance ?: MobileMissionConsoleHost().also { instance = it }
        }
    }
}
