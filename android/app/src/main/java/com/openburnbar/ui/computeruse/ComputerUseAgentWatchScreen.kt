// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import com.openburnbar.data.hermes.selectConnection

import com.openburnbar.data.hermes.refreshRelayConnections
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.computeruse.ComputerUseApprovalResponse
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.data.computeruse.ComputerUseWatchReducer
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import kotlinx.coroutines.launch

@Composable
fun rememberComputerUseWatchReducer(): ComputerUseWatchReducer = remember { ComputerUseWatchReducer() }

/**
 * Android Agent Watch surface. It mirrors the iOS first screen: full-bleed
 * watch area, trust-mode status, action timeline, approval controls, and a
 * long-press panic halt affordance.
 */
@Composable
fun ComputerUseAgentWatchScreen(
    reducer: ComputerUseWatchReducer = rememberComputerUseWatchReducer(),
    modifier: Modifier = Modifier,
    phoneControlSender: PhoneControlSender? = null,
    respondedBy: String = "android",
    onOpenHermes: (() -> Unit)? = null,
    onOpenSettings: (() -> Unit)? = null,
) {
    val state by reducer.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val hermesService = remember { HermesService(appContext = context.applicationContext) }
    val selectedConnection by hermesService.selectedConnection.collectAsState()
    val connections by hermesService.connections.collectAsState()
    LaunchedEffect(Unit) {
        runCatching { hermesService.refreshRelayConnections() }
    }
    val suggestedRelay =
        remember(connections) {
            connections
                .filter {
                    it.mode == HermesConnectionMode.RELAY_LINK &&
                        it.id != HermesConnectionRecord.localDefault.id
                }
                .maxByOrNull { it.lastSeenAt ?: 0L }
        }
    val fallbackOpenHermes: () -> Unit = {
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("burnbar://hermes")).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                },
            )
        }
    }
    val fallbackOpenSettings: () -> Unit = {
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("burnbar://you")).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                },
            )
        }
    }
    fun sendSignedApproval(
        response: ComputerUseApprovalResponse?,
        wireRequest: HermesRealtimeRelayApprovalRequest?,
    ) {
        wireRequest ?: return
        val sender = phoneControlSender ?: return
        val relayResponse = response?.toRelayApprovalResponse(respondedBy = respondedBy) ?: return
        scope.launch {
            runCatching {
                sender.send(
                    approvalResponse = relayResponse,
                    approvalRequest = wireRequest,
                )
            }.onFailure {
                reducer.deny("approval_send_failed")
            }
        }
    }
    ComputerUseAgentWatchContent(
        state = state,
        selectedConnection = selectedConnection,
        suggestedRelay = suggestedRelay,
        callbacks =
        AgentWatchCallbacks(
            onApprove = {
                val wireRequest = state.pendingApproval?.wireRequest
                val response = reducer.approve(System.currentTimeMillis())
                sendSignedApproval(response, wireRequest)
            },
            onReject = {
                val wireRequest = state.pendingApproval?.wireRequest
                val response = reducer.reject(halt = false, nowMillis = System.currentTimeMillis())
                sendSignedApproval(response, wireRequest)
            },
            onRejectAndHalt = {
                val wireRequest = state.pendingApproval?.wireRequest
                val response = reducer.reject(halt = true, nowMillis = System.currentTimeMillis())
                sendSignedApproval(response, wireRequest)
            },
            onDowngrade = reducer::downgradeTrustMode,
            onPanic = reducer::panicHalt,
            onOpenHermes = onOpenHermes ?: fallbackOpenHermes,
            onUseSuggestedRelay = {
                suggestedRelay?.let { hermesService.selectConnection(it) }
            },
            onOpenSettings = onOpenSettings ?: fallbackOpenSettings,
        ),
        modifier = modifier,
    )
}

internal fun ComputerUseApprovalResponse.toRelayApprovalResponse(respondedBy: String): HermesRealtimeRelayApprovalResponse =
    HermesRealtimeRelayApprovalResponse(
        approvalId = approvalId,
        decision =
        when {
            approved -> HermesRealtimeRelayApprovalResponse.Decision.APPROVE
            halt -> HermesRealtimeRelayApprovalResponse.Decision.REJECT_AND_HALT
            else -> HermesRealtimeRelayApprovalResponse.Decision.REJECT
        },
        respondedBy = respondedBy,
        respondedAt = respondedAtMillis.toDouble() / 1000.0 - 978_307_200.0,
        note =
        when {
            approved -> null
            halt -> "Rejected from Android and halted"
            else -> "Rejected from Android"
        },
    )

data class AgentWatchCallbacks(
    val onApprove: () -> Unit,
    val onReject: () -> Unit,
    val onRejectAndHalt: () -> Unit,
    val onDowngrade: (ComputerUseTrustMode) -> Unit,
    val onPanic: () -> Unit,
    val onOpenHermes: () -> Unit,
    val onUseSuggestedRelay: () -> Unit,
    val onOpenSettings: () -> Unit,
)
