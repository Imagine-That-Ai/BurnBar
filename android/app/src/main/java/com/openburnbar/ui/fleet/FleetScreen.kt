// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.fleet

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.fleet.FleetStore
import com.openburnbar.data.fleet.FleetUiState
import com.openburnbar.ui.theme.AuroraSpacing
import kotlinx.coroutines.delay

// MARK: - Fleet screen (Android)
//
// The Mac's fleet dashboard, read on a phone through the sealed
// `fleet_snapshot/current` mirror. Read-only in v1: orchestrator designation
// and directives stay Mac/daemon-local, so this surface renders truth and
// offers no controls. Structure and vocabulary mirror
// `AgentLens/Views/Dashboard/Fleet/FleetView.swift`.

/** How often the screen re-checks staleness without a new Firestore event. */
private const val STALENESS_RECHECK_MILLIS = 60_000L

@Composable
fun FleetScreen(store: FleetStore = viewModel(), modifier: Modifier = Modifier) {
    DisposableEffect(store) {
        store.startListening()
        onDispose { store.stopListening() }
    }
    // A mirror that quietly stops updating must cross into the Mac-offline
    // state on its own; no Firestore event will arrive to prompt it.
    LaunchedEffect(store) {
        while (true) {
            delay(STALENESS_RECHECK_MILLIS)
            store.refreshDerivedState()
        }
    }

    val state by store.state.collectAsState()
    val isVaultReady by store.isVaultReady.collectAsState()
    val error by store.error.collectAsState()
    val nowEpoch = System.currentTimeMillis()

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = AuroraSpacing.LG.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
        FleetHeader(state = state, nowEpoch = nowEpoch)
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
        if (!isVaultReady) {
            FleetVaultNotReadyCard()
            return@Column
        }
        error?.let { FleetErrorBanner(message = it) }
        FleetStateContent(state = state, nowEpoch = nowEpoch)
    }
}

@Composable
private fun FleetStateContent(state: FleetUiState, nowEpoch: Long) {
    when (state) {
        is FleetUiState.Loading -> FleetLoadingState()
        is FleetUiState.MacOffline -> FleetMacOfflineCard(lastUpdatedAtEpoch = state.lastUpdatedAtEpoch, nowEpoch = nowEpoch)
        is FleetUiState.Empty -> FleetEmptyCard(updatedAtEpoch = state.updatedAtEpoch, nowEpoch = nowEpoch)
        is FleetUiState.Ready ->
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
            ) {
                fleetDashboardItems(snapshot = state.snapshot, updatedAtEpoch = state.updatedAtEpoch, nowEpoch = nowEpoch)
            }
    }
}
