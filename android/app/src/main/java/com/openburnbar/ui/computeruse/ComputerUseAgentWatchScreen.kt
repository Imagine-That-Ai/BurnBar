// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

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
import com.openburnbar.data.computeruse.AgentWatchControlFrameReceiver
import com.openburnbar.data.computeruse.ComputerUseApprovalResponse
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.data.computeruse.ComputerUseWatchReducer
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.refreshRelayConnections
import com.openburnbar.data.hermes.selectConnection
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
    // RR-7b: run the Agent Watch INGEST receiver against the live control stream so an inbound
    // control.approvalRequest populates the reducer's pendingApproval WITH its wireRequest. When no
    // coordinator/pair is active (e.g. the settings entry with no paired Mac) the loop is inert.
    val coordinator = remember { com.openburnbar.BurnBarApplication.mediaControlCoordinator }
    val activePair by (coordinator?.activePair ?: kotlinx.coroutines.flow.MutableStateFlow(null)).collectAsState()
    LaunchedEffect(coordinator, activePair?.uid, activePair?.connectionID) {
        val pair = activePair ?: return@LaunchedEffect
        val receiver = AgentWatchControlFrameReceiver(reducer, uid = pair.uid, connectionId = pair.connectionID)
        coordinator?.agentWatchControlFrames?.collect { receiver.ingest(it) }
    }
    val effectiveSender = phoneControlSender ?: phoneControlSenderFor(activePair)
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
    fun sendSignedApproval(response: ComputerUseApprovalResponse?, wireRequest: HermesRealtimeRelayApprovalRequest?) {
        wireRequest ?: return
        val sender = effectiveSender ?: return
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

/**
 * RR-7b — the live [PhoneControlSender] for the currently paired Mac, or null when no control stream
 * is established. The mirror surfaces (ScreenShareViewer / InlineAgentMirror) publish their sender to
 * [com.openburnbar.BurnBarApplication.activePhoneControlSender] when a stream is live; the watch
 * surface reuses it so a phone-side approval is signed + transmitted over the same connection.
 */
private fun phoneControlSenderFor(activePair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair?): PhoneControlSender? {
    activePair ?: return null
    return com.openburnbar.BurnBarApplication.activePhoneControlSender
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
        // RR-7b respondedAt canonicalization: emit WHOLE Swift-reference SECONDS so the canonical
        // number renders as a plain integer on BOTH sides — Android `PhoneControlSignerJsonEncoding
        // .number()` returns the integer form for an integer-valued Double, and Swift's verifier
        // `JSONEncoder` (default `Date` → `timeIntervalSinceReferenceDate`) likewise emits an integer
        // for a whole-second Date. Carrying sub-second fractions would diverge the two number
        // formatters and break the Swift↔Kotlin approval-response hash (locked by the KAT below).
        respondedAt = (respondedAtMillis / 1000L).toDouble() - 978_307_200.0,
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
