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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.data.computeruse.ComputerUseWatchReducer
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesService

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
    onOpenHermes: (() -> Unit)? = null,
    onOpenSettings: (() -> Unit)? = null,
) {
    val state by reducer.state.collectAsState()
    val context = LocalContext.current
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
    ComputerUseAgentWatchContent(
        state = state,
        selectedConnection = selectedConnection,
        suggestedRelay = suggestedRelay,
        callbacks =
        AgentWatchCallbacks(
            onApprove = { reducer.approve(System.currentTimeMillis()) },
            onReject = { reducer.reject(halt = false, nowMillis = System.currentTimeMillis()) },
            onRejectAndHalt = { reducer.reject(halt = true, nowMillis = System.currentTimeMillis()) },
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
