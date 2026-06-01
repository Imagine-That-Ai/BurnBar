package com.openburnbar.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.data.media.AndroidMediaCapabilityGate
import com.openburnbar.data.media.MediaPartnerSavePreferenceStore
import com.openburnbar.data.media.MercuryAutoKeyboardPreference
import com.openburnbar.data.square.MercuryPairedMacTilePreference

/**
 * Compose port of iOS `MediaSettingsView.swift` + `PerPartnerSavePreferencesView.swift`.
 */
@Composable
fun MediaSettingsView(
    capabilityGate: AndroidMediaCapabilityGate = remember { AndroidMediaCapabilityGate() },
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val store = remember { MediaPartnerSavePreferenceStore(context) }
    val partners by store.storedPartnersFlow().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    var showPairedMacTile by remember(context) {
        mutableStateOf(MercuryPairedMacTilePreference.isEnabled(context))
    }
    var autoKeyboardOnTextFocus by remember(context) {
        mutableStateOf(MercuryAutoKeyboardPreference.isEnabled(context))
    }
    var killSwitchReason by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(capabilityGate) {
        killSwitchReason = mediaSettingsKillSwitchReason(capabilityGate)
    }

    LazyColumn(
        modifier = modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        killSwitchReason?.let { reason ->
            item { MediaSettingsKillSwitchBanner(reason = reason) }
        }
        item { MediaSettingsSectionLabel("Calls & screen share") }
        item {
            MediaSettingsAutoKeyboardRow(
                enabled = autoKeyboardOnTextFocus,
                onEnabledChange = { enabled ->
                    autoKeyboardOnTextFocus = enabled
                    MercuryAutoKeyboardPreference.setEnabled(context, enabled)
                },
            )
        }
        item { MediaSettingsSectionLabel("Mercury") }
        item {
            MediaSettingsPairedMacTileRow(
                enabled = showPairedMacTile,
                onEnabledChange = { enabled ->
                    showPairedMacTile = enabled
                    MercuryPairedMacTilePreference.setEnabled(context, enabled)
                },
            )
        }
        item { MediaSettingsSectionLabel("Per-partner save preferences") }
        mediaSettingsPartnerItems(partners = partners, scope = scope, store = store)
    }
}
