// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.media.AndroidMediaCapabilityGate
import com.openburnbar.data.media.MediaPartnerSavePreferenceStore
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@Composable
internal fun MediaSettingsKillSwitchBanner(reason: String) {
    val isDark = isSystemInDarkTheme()
    val textPrimaryColor = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
    val textSecondaryColor = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary

    val mercuryBrush =
        Brush.horizontalGradient(
            listOf(
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
                AuroraColors.hermesAureate.copy(alpha = 0.7f),
            ),
        )
    Row(
        modifier =
        Modifier
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
                color = textPrimaryColor,
            )
            Text(
                text = reason,
                color = textSecondaryColor,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@Composable
internal fun MediaSettingsSectionLabel(text: String) {
    val isDark = isSystemInDarkTheme()
    Text(
        text = text,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary,
    )
}

@Composable
internal fun MediaSettingsAutoKeyboardRow(enabled: Boolean, onEnabledChange: (Boolean) -> Unit) {
    MediaSettingsToggleRow(
        title = "Auto keyboard on text focus",
        detail = "Opens the phone keyboard when your Mac focuses a text field. Smart Zoom still controls framing.",
        checked = enabled,
        onCheckedChange = onEnabledChange,
    )
}

@Composable
internal fun MediaSettingsPairedMacTileRow(enabled: Boolean, onEnabledChange: (Boolean) -> Unit) {
    MediaSettingsToggleRow(
        title = "Show My Mac on Hermes Square",
        detail = "Keep screen share, calls, and file transfer one tap away while Mercury connects.",
        checked = enabled,
        onCheckedChange = onEnabledChange,
    )
}

internal fun LazyListScope.mediaSettingsPartnerItems(
    partners: List<Pair<String, MediaPartnerSavePreferenceStore.SavePreference>>,
    scope: CoroutineScope,
    store: MediaPartnerSavePreferenceStore,
) {
    if (partners.isEmpty()) {
        item {
            val isDark = isSystemInDarkTheme()
            Text(
                text = "No saved partners yet. The first image you accept from a paired Mac will prompt to choose Photos or Files.",
                color = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary,
            )
        }
        return
    }
    items(partners, key = { it.first }) { (peerId, pref) ->
        val isDark = isSystemInDarkTheme()
        val dividerColor = if (isDark) AuroraColors.darkBorderSubtle else AuroraColors.lightBorderSubtle
        MediaSettingsPartnerRow(
            peerId = peerId,
            pref = pref,
            onForget = { scope.launch { store.forget(peerId) } },
        )
        HorizontalDivider(color = dividerColor)
    }
    item {
        TextButton(onClick = { scope.launch { store.forgetAll() } }) {
            Text("Forget all partners")
        }
    }
}

@Composable
private fun MediaSettingsPartnerRow(peerId: String, pref: MediaPartnerSavePreferenceStore.SavePreference, onForget: () -> Unit) {
    val isDark = isSystemInDarkTheme()
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = peerId.take(16) + "…",
                fontFamily = FontFamily.Monospace,
                color = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary,
            )
            Text(
                text = "Saves to: ${pref.raw}",
                color = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary,
                fontSize = 12.sp,
            )
        }
        TextButton(onClick = onForget) { Text("Forget") }
    }
}

@Composable
private fun MediaSettingsToggleRow(title: String, detail: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val isDark = isSystemInDarkTheme()
    val cardBackground = if (isDark) AuroraColors.darkSurfaceElevated.copy(alpha = 0.64f) else AuroraColors.lightSurfaceElevated.copy(alpha = 0.64f)
    val cardBorder = if (isDark) AuroraColors.darkBorderSubtle else AuroraColors.lightBorderSubtle
    val textPrimaryColor = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
    val textSecondaryColor = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(cardBackground)
            .border(1.dp, cardBorder, RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = textPrimaryColor)
            Text(detail, color = textSecondaryColor, fontSize = 12.sp)
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

internal suspend fun mediaSettingsKillSwitchReason(capabilityGate: AndroidMediaCapabilityGate): String? {
    val result = capabilityGate.check(com.openburnbar.data.media.MediaStreamClass.Feature.FILE_TRANSFER)
    return when (result) {
        is AndroidMediaCapabilityGate.Check.Allowed -> null
        is AndroidMediaCapabilityGate.Check.Denied -> result.reason.raw
    }
}
