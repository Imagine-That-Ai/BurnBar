package com.openburnbar.ui.insights

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
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
        authListener = FirebaseAuth.AuthStateListener { restartListListener(it.currentUser?.uid) }
        auth.addAuthStateListener(authListener!!)
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
            } catch (e: Exception) {
                _status.value = InsightsViewModel.MissionStatus.Failed(
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
        listRegistration = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .limit(6)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    _status.value = InsightsViewModel.MissionStatus.Failed(
                        "Mission listener",
                        error.message ?: "Mission listener failed.",
                    )
                    return@addSnapshotListener
                }
                val selected = snapshot?.documents.orEmpty()
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
        observationJob = viewModelScope.launch {
            dispatcher.observe(requestID)
                .catch { e ->
                    _status.value = InsightsViewModel.MissionStatus.Failed(
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
        private val TERMINAL_STATUSES = setOf(
            "completed",
            "failed",
            "canceled",
            "cancelled",
            "unauthorized",
            "agent_launch_failed",
        )
    }
}

@Composable
fun MissionActivityOverlay(
    modifier: Modifier = Modifier,
    viewModel: MissionActivityViewModel = viewModel(),
) {
    val status by viewModel.status.collectAsState()
    var showMissionDetail by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.start() }

    Box(modifier = modifier, contentAlignment = Alignment.BottomEnd) {
        when (val current = status) {
            InsightsViewModel.MissionStatus.Idle -> Unit
            is InsightsViewModel.MissionStatus.Tracking -> {
                val mission = current.mission
                ExtendedFloatingActionButton(
                    onClick = { showMissionDetail = true },
                    icon = {
                        Icon(
                            imageVector = if (mission.isTerminal) Icons.Filled.CheckCircle else Icons.Filled.GraphicEq,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = if (mission.isTerminal) "Mission done" else "Mission live",
                                style = AuroraType.tiny.copy(fontWeight = FontWeight.SemiBold),
                            )
                        }
                    },
                    containerColor = if (mission.isTerminal) {
                        InsightsColors.kpiPositive
                    } else {
                        MaterialTheme.colorScheme.primary
                    },
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier
                        .padding(AuroraSpacing.lg.dp)
                        .clip(CircleShape),
                )
            }
            is InsightsViewModel.MissionStatus.Failed -> {
                ExtendedFloatingActionButton(
                    onClick = { showMissionDetail = true },
                    icon = {
                        Icon(Icons.Filled.WarningAmber, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    text = {
                        Text(
                            text = "Mission alert",
                            style = AuroraType.tiny.copy(fontWeight = FontWeight.SemiBold),
                        )
                    },
                    containerColor = MaterialTheme.colorScheme.error,
                    contentColor = MaterialTheme.colorScheme.onError,
                    modifier = Modifier
                        .padding(AuroraSpacing.lg.dp)
                        .clip(RoundedCornerShape(28.dp)),
                )
            }
            is InsightsViewModel.MissionStatus.Dispatched -> Unit
        }
    }

    if (showMissionDetail) {
        MissionDetailSheet(
            status = status,
            onApprovalResponse = { requestID, approve ->
                viewModel.respondToMissionApproval(requestID, approve)
            },
            onDismiss = { showMissionDetail = false },
        )
    }
}
