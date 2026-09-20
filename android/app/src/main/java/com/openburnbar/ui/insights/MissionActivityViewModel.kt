package com.openburnbar.ui.insights

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.assistants.SkillRunEventImportance
import com.openburnbar.data.insights.services.BurnBarProSubscriptionRequiredException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

class MissionActivityViewModel : ViewModel() {
    private val auth = FirebaseAuth.getInstance()
    private val firestore = FirebaseFirestore.getInstance()
    private val dispatcher = CLIAgentMissionDispatcher(auth, firestore)
    private val dismissedMissionIDs = mutableSetOf<String>()

    private var listRegistration: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var observedMissionID: String? = null
    private var observationJob: Job? = null

    private val _status = MutableStateFlow<InsightsViewModel.MissionStatus>(InsightsViewModel.MissionStatus.Idle)
    val status = _status.asStateFlow()

    fun start() {
        if (authListener != null) return
        val listener = FirebaseAuth.AuthStateListener { restartListListener(it.currentUser?.uid) }
        authListener = listener
        auth.addAuthStateListener(listener)
        restartListListener(auth.currentUser?.uid)
    }

    fun dismissCurrent() {
        val current = _status.value
        if (current is InsightsViewModel.MissionStatus.Tracking) {
            dismissedMissionIDs += current.mission.id
        }
        observationJob?.cancel()
        observationJob = null
        observedMissionID = null
        _status.value = InsightsViewModel.MissionStatus.Idle
    }

    fun respondToMissionApproval(requestID: String, approve: Boolean) {
        viewModelScope.launch {
            try {
                dispatcher.respondToApproval(requestID, approve)
            } catch (e: BurnBarProSubscriptionRequiredException) {
                _status.value =
                    InsightsViewModel.MissionStatus.Failed(
                        "Mission approval",
                        e.message ?: "Mission approval response failed.",
                    )
            }
        }
    }

    private fun restartListListener(uid: String?) {
        listRegistration?.remove()
        listRegistration = null
        observationJob?.cancel()
        observationJob = null
        observedMissionID = null
        if (uid == null) {
            _status.value = InsightsViewModel.MissionStatus.Idle
            return
        }
        listRegistration =
            firestore.collection("users").document(uid)
                .collection("cli_agent_mission_requests")
                .orderBy("createdAt", Query.Direction.DESCENDING)
                .limit(MISSION_LIST_LIMIT)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        _status.value =
                            InsightsViewModel.MissionStatus.Failed(
                                "Mission listener",
                                error.message ?: "Mission listener failed.",
                            )
                        return@addSnapshotListener
                    }
                    val selected =
                        snapshot?.documents.orEmpty()
                            .filterNot { it.id in dismissedMissionIDs }
                            .firstOrNull { doc -> doc.getString("status") !in TERMINAL_STATUSES }
                            ?: snapshot?.documents.orEmpty().firstOrNull { it.id !in dismissedMissionIDs }
                    if (selected == null) {
                        _status.value = InsightsViewModel.MissionStatus.Idle
                        return@addSnapshotListener
                    }
                    observeMission(selected.id)
                }
    }

    private fun observeMission(requestID: String) {
        if (requestID == observedMissionID) return
        observedMissionID = requestID
        observationJob?.cancel()
        observationJob =
            viewModelScope.launch {
                dispatcher.observe(requestID)
                    .catch { e ->
                        _status.value =
                            InsightsViewModel.MissionStatus.Failed(
                                "Mission listener",
                                e.message ?: "Mission listener failed.",
                            )
                    }
                    .collect { snapshot ->
                        _status.value = InsightsViewModel.MissionStatus.Tracking(snapshot)
                    }
            }
    }

    override fun onCleared() {
        authListener?.let(auth::removeAuthStateListener)
        listRegistration?.remove()
        observationJob?.cancel()
        super.onCleared()
    }

    companion object {
        private const val MISSION_LIST_LIMIT = 6L

        private val TERMINAL_STATUSES =
            setOf(
                "completed",
                "failed",
                "canceled",
                "cancelled",
                "unauthorized",
                "agent_launch_failed",
            )
    }
}

fun shouldAutoOpenSkillRun(mission: CLIAgentMissionSnapshot): Boolean = when (mission.deliveryMode) {
    SkillRunDeliveryMode.FULL_STREAM -> true
    SkillRunDeliveryMode.ACTION_ONLY ->
        mission.isWaitingForApproval ||
            mission.isTerminal ||
            mission.events.lastOrNull()?.eventImportance in
            setOf(
                SkillRunEventImportance.ACTION_REQUIRED,
                SkillRunEventImportance.TERMINAL,
            )
    SkillRunDeliveryMode.MUTED -> false
}

fun skillRunNotificationKey(mission: CLIAgentMissionSnapshot): String {
    val latest = mission.events.lastOrNull()
    val shouldResurface =
        mission.isWaitingForApproval ||
            mission.isTerminal ||
            latest?.eventImportance in
            setOf(
                SkillRunEventImportance.ACTION_REQUIRED,
                SkillRunEventImportance.TERMINAL,
            )
    if (!shouldResurface) {
        return listOf(
            mission.id,
            mission.deliveryMode.wire,
            "passive",
        ).joinToString("|")
    }
    return listOf(
        mission.id,
        mission.status,
        mission.deliveryMode.wire,
        mission.approvalStatus ?: "none",
        latest?.sequence?.toString() ?: "-1",
        latest?.eventImportance?.wire ?: "none",
        latest?.phase ?: "none",
    ).joinToString("|")
}
