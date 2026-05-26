package com.openburnbar.ui.computeruse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.computeruse.PhoneControlSystemPermissionKind
import com.openburnbar.data.computeruse.SystemPermissionItem
import com.openburnbar.data.computeruse.SystemPermissionStatus

private val MercuryStart = Color(0xFFC8BFB5)
private val MercuryEnd = Color(0xFFA2ACBA)
private val MercuryBrush = Brush.linearGradient(listOf(MercuryStart, MercuryEnd))

/**
 * Phase 14 — Android counterpart of the iOS `SystemPermissionInlinePill`.
 * Renders directly below the assistant tool-call strip when a TCC
 * failure is bound to this message. Tap promotes to the full bottom
 * sheet.
 */
@Composable
fun SystemPermissionInlinePill(
    item: SystemPermissionItem,
    onTap: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
            .border(1.dp, MercuryBrush, RoundedCornerShape(14.dp))
            .clickable { onTap() }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).background(MercuryBrush, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(headline(item), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle(item), fontSize = 11.sp)
        }
        trailing(item.status)
    }
}

@Composable
private fun trailing(status: SystemPermissionStatus) {
    when (status) {
        SystemPermissionStatus.GRANTED -> Icon(Icons.Filled.CheckCircle, null, tint = Color(0xFF34D399), modifier = Modifier.size(20.dp))
        SystemPermissionStatus.DENIED -> Icon(Icons.Filled.Warning, null, tint = Color(0xFFFBBF24), modifier = Modifier.size(20.dp))
        SystemPermissionStatus.REQUESTING -> CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        else -> Icon(Icons.Filled.Lock, null, tint = MercuryEnd, modifier = Modifier.size(20.dp))
    }
}

private fun headline(item: SystemPermissionItem): String = when (item.status) {
    SystemPermissionStatus.NEEDS_ACCESS,
    SystemPermissionStatus.TIMEOUT,
    SystemPermissionStatus.UNKNOWN -> "Grant ${displayTitle(item.kind)} on your Mac"

    SystemPermissionStatus.REQUESTING -> "Granting ${displayTitle(item.kind)}…"
    SystemPermissionStatus.GRANTED -> "${displayTitle(item.kind)} is on"
    SystemPermissionStatus.DENIED -> "${displayTitle(item.kind)} was denied"
}

private fun subtitle(item: SystemPermissionItem): String = when (item.status) {
    SystemPermissionStatus.NEEDS_ACCESS,
    SystemPermissionStatus.TIMEOUT,
    SystemPermissionStatus.UNKNOWN -> "Tap to send a one-tap request to your Mac."

    SystemPermissionStatus.REQUESTING -> "Watching for the system prompt…"
    SystemPermissionStatus.GRANTED -> item.originatingToolName?.let { "Auto-retrying $it…" }
        ?: "Auto-retrying the blocked tool…"

    SystemPermissionStatus.DENIED -> "Tap to retry or open System Settings."
}

private fun displayTitle(kind: PhoneControlSystemPermissionKind): String = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING -> "Screen Recording"
    PhoneControlSystemPermissionKind.ACCESSIBILITY -> "Accessibility"
    PhoneControlSystemPermissionKind.CAMERA -> "Camera"
    PhoneControlSystemPermissionKind.MICROPHONE -> "Microphone"
    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> "Full Disk Access"
    PhoneControlSystemPermissionKind.AUTOMATION -> "Automation"
}
