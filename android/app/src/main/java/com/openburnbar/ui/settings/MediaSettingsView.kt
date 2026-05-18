package com.openburnbar.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.media.AndroidMediaCapabilityGate
import com.openburnbar.data.media.MediaPartnerSavePreferenceStore
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Compose port of iOS `MediaSettingsView.swift` + `PerPartnerSavePreferencesView.swift`.
 * Per-partner save preferences list + media kill-switch banner. The
 * media kill switch is server-driven via the capability gate (Decision
 * 2 — Mac authoritative); Android surfaces the resolved state.
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

    var killSwitchReason by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(capabilityGate) {
        // Mac is authoritative — we surface the Mercury denial reason
        // when the gate refuses any feature.
        val result = capabilityGate.check(com.openburnbar.data.media.MediaStreamClass.Feature.FILE_TRANSFER)
        killSwitchReason = when (result) {
            is AndroidMediaCapabilityGate.Check.Allowed -> null
            is AndroidMediaCapabilityGate.Check.Denied -> result.reason.raw
        }
    }

    val mercuryBrush = Brush.horizontalGradient(
        listOf(
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
            AuroraColors.hermesAureate.copy(alpha = 0.7f),
        )
    )

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (killSwitchReason != null) {
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(AuroraColors.warning.copy(alpha = 0.10f))
                        .border(width = 1.dp, brush = mercuryBrush, shape = RoundedCornerShape(12.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Info, contentDescription = null, tint = AuroraColors.warning)
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(
                            text = "Mercury Media unavailable",
                            fontWeight = FontWeight.SemiBold,
                            color = AuroraColors.darkTextPrimary,
                        )
                        Text(
                            text = killSwitchReason ?: "",
                            color = AuroraColors.darkTextSecondary,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
        }

        item {
            Text(
                text = "Per-partner save preferences",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.darkTextSecondary,
            )
        }

        if (partners.isEmpty()) {
            item {
                Text(
                    text = "No saved partners yet. The first image you accept from a paired Mac will prompt to choose Photos or Files.",
                    color = AuroraColors.darkTextSecondary,
                )
            }
        } else {
            items(partners, key = { it.first }) { (peerId, pref) ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = peerId.take(16) + "…",
                            fontFamily = FontFamily.Monospace,
                            color = AuroraColors.darkTextPrimary,
                        )
                        Text(
                            text = "Saves to: ${pref.raw}",
                            color = AuroraColors.darkTextSecondary,
                            fontSize = 12.sp,
                        )
                    }
                    TextButton(onClick = { scope.launch { store.forget(peerId) } }) { Text("Forget") }
                }
                HorizontalDivider(color = AuroraColors.darkBorderSubtle)
            }
            item {
                TextButton(onClick = { scope.launch { store.forgetAll() } }) {
                    Text("Forget all partners")
                }
            }
        }
    }
}
