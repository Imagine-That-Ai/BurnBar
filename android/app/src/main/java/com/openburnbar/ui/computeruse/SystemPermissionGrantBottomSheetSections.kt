@file:Suppress("MagicNumber", "LongParameterList")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.computeruse.PhoneControlSystemPermissionAction
import com.openburnbar.data.computeruse.PhoneControlSystemPermissionKind
import com.openburnbar.data.computeruse.PhoneControlSystemPermissionRequest
import com.openburnbar.data.computeruse.SystemPermissionItem
import com.openburnbar.data.computeruse.SystemPermissionStatus
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private val MercuryStart = Color(0xFFC8BFB5)
private val MercuryEnd = Color(0xFFA2ACBA)
private val MercuryBrush = Brush.linearGradient(listOf(MercuryStart, MercuryEnd))

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SystemPermissionGrantBottomSheetContent(
    item: SystemPermissionItem,
    onDismiss: () -> Unit,
    sendPermissionRequest: suspend (PhoneControlSystemPermissionRequest) -> Result<Unit>,
) {
    val scope = rememberCoroutineScope()
    var isSending by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        SystemPermissionGrantSheetBody(
            item = item,
            isSending = isSending,
            errorMessage = errorMessage,
            callbacks =
            SystemPermissionGrantSheetCallbacks(
                scope = scope,
                sendPermissionRequest = sendPermissionRequest,
                onSendingChange = { isSending = it },
                onErrorMessageChange = { errorMessage = it },
            ),
        )
    }
}

private data class SystemPermissionGrantSheetCallbacks(
    val scope: CoroutineScope,
    val sendPermissionRequest: suspend (PhoneControlSystemPermissionRequest) -> Result<Unit>,
    val onSendingChange: (Boolean) -> Unit,
    val onErrorMessageChange: (String?) -> Unit,
)

@Composable
private fun SystemPermissionGrantSheetBody(
    item: SystemPermissionItem,
    isSending: Boolean,
    errorMessage: String?,
    callbacks: SystemPermissionGrantSheetCallbacks,
) {
    val scope = callbacks.scope
    val sendPermissionRequest = callbacks.sendPermissionRequest
    val onSendingChange = callbacks.onSendingChange
    val onErrorMessageChange = callbacks.onErrorMessageChange
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        heroBlock(item)
        statusCard(item)
        ctaStack(
            item = item,
            isSending = isSending,
            onPrimary = {
                scope.launchPermissionDispatch(
                    action = defaultActionFor(item.kind),
                    item = item,
                    sendRequest = sendPermissionRequest,
                    onError = onErrorMessageChange,
                    onLoading = onSendingChange,
                )
            },
            onOpenSettings = {
                scope.launchPermissionDispatch(
                    action = PhoneControlSystemPermissionAction.OPEN_SETTINGS,
                    item = item,
                    sendRequest = sendPermissionRequest,
                    onError = onErrorMessageChange,
                    onLoading = onSendingChange,
                )
            },
            onRetry = {
                scope.launchPermissionDispatch(
                    action = PhoneControlSystemPermissionAction.RETRY_FAILED_TOOL,
                    item = item,
                    sendRequest = sendPermissionRequest,
                    onError = onErrorMessageChange,
                    onLoading = onSendingChange,
                )
            },
        )
        instructionsFooter(item)
        errorMessage?.let { msg ->
            Text(text = msg, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
        }
    }
}

private fun CoroutineScope.launchPermissionDispatch(
    action: PhoneControlSystemPermissionAction,
    item: SystemPermissionItem,
    sendRequest: suspend (PhoneControlSystemPermissionRequest) -> Result<Unit>,
    onError: (String?) -> Unit,
    onLoading: (Boolean) -> Unit,
) {
    launch {
        dispatch(
            action = action,
            item = item,
            sendRequest = sendRequest,
            onError = onError,
            onLoading = onLoading,
        )
    }
}

@Composable
private fun heroBlock(item: SystemPermissionItem) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .size(48.dp)
                    .background(MercuryBrush, RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = Color.White)
            }
            Column(modifier = Modifier.padding(start = 12.dp)) {
                Text(displayTitle(item.kind), fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(displaySubtitle(item.kind), fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }
        Text(heroExplanation(item.kind), fontSize = 14.sp)
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(MercuryBrush))
    }
}

@Composable
private fun statusCard(item: SystemPermissionItem) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(14.dp))
            .border(1.dp, MercuryBrush, RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        statusIcon(item.status)
        Column(modifier = Modifier.weight(1f)) {
            Text(statusHeadline(item.status), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text(statusSubtitle(item.status), fontSize = 12.sp)
        }
    }
}

@Composable
private fun statusIcon(status: SystemPermissionStatus) {
    when (status) {
        SystemPermissionStatus.GRANTED -> Icon(Icons.Filled.CheckCircle, null, tint = Color(0xFF34D399), modifier = Modifier.size(28.dp))
        SystemPermissionStatus.DENIED -> Icon(Icons.Filled.Block, null, tint = Color(0xFFFBBF24), modifier = Modifier.size(28.dp))
        SystemPermissionStatus.REQUESTING -> CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
        else -> Icon(Icons.Filled.Lock, null, tint = MercuryEnd, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun ctaStack(item: SystemPermissionItem, isSending: Boolean, onPrimary: () -> Unit, onOpenSettings: () -> Unit, onRetry: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(
            onClick = onPrimary,
            enabled = item.status.allowsRetap && !isSending,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = MercuryEnd, contentColor = Color.White),
        ) {
            Icon(Icons.Filled.CheckCircle, null, modifier = Modifier.size(16.dp))
            Text("  ${primaryTitle(item.status)}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        OutlinedButton(onClick = onOpenSettings, enabled = !isSending, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.Settings, null, modifier = Modifier.size(16.dp))
            Text("  Open System Settings on Mac", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        OutlinedButton(onClick = onRetry, enabled = !isSending, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.Refresh, null, modifier = Modifier.size(16.dp))
            Text(
                "  ${if (item.status == SystemPermissionStatus.GRANTED) "Retry now" else "Retry once granted"}",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun instructionsFooter(item: SystemPermissionItem) {
    val steps = numberedInstructions(item.kind, item.bundleId)
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp))
            .border(1.dp, Color(0x33C8BFB5), RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("On your Mac", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MercuryEnd)
        steps.forEachIndexed { idx, step ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(String.format(java.util.Locale.US, "%02d", idx + 1), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = MercuryStart)
                Text(step, fontSize = 13.sp)
            }
        }
    }
}

private suspend fun dispatch(
    action: PhoneControlSystemPermissionAction,
    item: SystemPermissionItem,
    sendRequest: suspend (PhoneControlSystemPermissionRequest) -> Result<Unit>,
    onError: (String?) -> Unit,
    onLoading: (Boolean) -> Unit,
) {
    onLoading(true)
    onError(null)
    val request =
        PhoneControlSystemPermissionRequest(
            requestId = UUID.randomUUID().toString(),
            kind = item.kind,
            action = action,
            bundleId = item.bundleId,
            originatingToolCallId = item.originatingToolCallId,
            originatingToolName = item.originatingToolName,
            clientIntentId = UUID.randomUUID().toString(),
            requestedAtMillis = System.currentTimeMillis(),
        )
    val result = sendRequest(request)
    if (result.isFailure) {
        onError(result.exceptionOrNull()?.localizedMessage ?: "Could not send request.")
    }
    onLoading(false)
}

private fun displayTitle(kind: PhoneControlSystemPermissionKind): String = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING -> "Screen Recording"
    PhoneControlSystemPermissionKind.ACCESSIBILITY -> "Accessibility"
    PhoneControlSystemPermissionKind.CAMERA -> "Camera"
    PhoneControlSystemPermissionKind.MICROPHONE -> "Microphone"
    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> "Full Disk Access"
    PhoneControlSystemPermissionKind.AUTOMATION -> "Automation"
}

private fun displaySubtitle(kind: PhoneControlSystemPermissionKind): String = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING -> "on your Mac"
    PhoneControlSystemPermissionKind.ACCESSIBILITY -> "for OpenBurnBar"
    PhoneControlSystemPermissionKind.CAMERA -> "on your Mac"
    PhoneControlSystemPermissionKind.MICROPHONE -> "on your Mac"
    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> "for OpenBurnBar"
    PhoneControlSystemPermissionKind.AUTOMATION -> "for the requested app"
}

private fun heroExplanation(kind: PhoneControlSystemPermissionKind): String = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING -> "Your Mac needs Screen Recording so OpenBurnBar can grab the screen for this agent."
    PhoneControlSystemPermissionKind.ACCESSIBILITY -> "Your Mac needs Accessibility so OpenBurnBar can drive clicks and keystrokes for this agent."
    PhoneControlSystemPermissionKind.CAMERA -> "Your Mac needs Camera access so OpenBurnBar can read the camera for this agent."
    PhoneControlSystemPermissionKind.MICROPHONE -> "Your Mac needs Microphone access so OpenBurnBar can capture audio for this agent."
    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> "Your Mac needs Full Disk Access so OpenBurnBar can reach this folder for the agent."
    PhoneControlSystemPermissionKind.AUTOMATION -> "Your Mac needs Automation access so OpenBurnBar can drive the target app for this agent."
}

private fun defaultActionFor(kind: PhoneControlSystemPermissionKind): PhoneControlSystemPermissionAction = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING,
    PhoneControlSystemPermissionKind.ACCESSIBILITY,
    PhoneControlSystemPermissionKind.AUTOMATION,
    -> PhoneControlSystemPermissionAction.PROMPT_AND_OPEN_SETTINGS

    PhoneControlSystemPermissionKind.CAMERA,
    PhoneControlSystemPermissionKind.MICROPHONE,
    -> PhoneControlSystemPermissionAction.PROMPT

    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> PhoneControlSystemPermissionAction.OPEN_SETTINGS
}

private fun statusHeadline(status: SystemPermissionStatus): String = when (status) {
    SystemPermissionStatus.NEEDS_ACCESS -> "Ready to request on your Mac"
    SystemPermissionStatus.REQUESTING -> "Asking macOS for permission…"
    SystemPermissionStatus.GRANTED -> "Permission granted"
    SystemPermissionStatus.DENIED -> "macOS denied the request"
    SystemPermissionStatus.TIMEOUT -> "macOS did not respond in time"
    SystemPermissionStatus.UNKNOWN -> "Permission state unknown"
}

private fun statusSubtitle(status: SystemPermissionStatus): String = when (status) {
    SystemPermissionStatus.NEEDS_ACCESS -> "OpenBurnBar on your Mac will surface the prompt and System Settings deep link."
    SystemPermissionStatus.REQUESTING -> "Watch your Mac for the native dialog or System Settings pane."
    SystemPermissionStatus.GRANTED -> "Auto-retrying the blocked tool so the agent can finish."
    SystemPermissionStatus.DENIED -> "Tap Retry once you've toggled OpenBurnBar on in System Settings."
    SystemPermissionStatus.TIMEOUT -> "Tap Retry to send the request again."
    SystemPermissionStatus.UNKNOWN -> "Tap Send to retry."
}

private fun primaryTitle(status: SystemPermissionStatus): String = when (status) {
    SystemPermissionStatus.GRANTED -> "Already granted"
    SystemPermissionStatus.REQUESTING -> "Awaiting macOS…"
    else -> "Grant on this Mac"
}

private fun numberedInstructions(kind: PhoneControlSystemPermissionKind, bundleName: String?): List<String> = when (kind) {
    PhoneControlSystemPermissionKind.SCREEN_RECORDING ->
        listOf(
            "Open System Settings on your Mac",
            "Go to Privacy & Security → Screen Recording",
            "Toggle OpenBurnBar on",
        )
    PhoneControlSystemPermissionKind.ACCESSIBILITY ->
        listOf(
            "Open System Settings on your Mac",
            "Go to Privacy & Security → Accessibility",
            "Toggle OpenBurnBar on",
        )
    PhoneControlSystemPermissionKind.CAMERA ->
        listOf(
            "On your Mac, accept the camera prompt",
            "Or open Privacy & Security → Camera",
            "Toggle OpenBurnBar on",
        )
    PhoneControlSystemPermissionKind.MICROPHONE ->
        listOf(
            "On your Mac, accept the microphone prompt",
            "Or open Privacy & Security → Microphone",
            "Toggle OpenBurnBar on",
        )
    PhoneControlSystemPermissionKind.FULL_DISK_ACCESS ->
        listOf(
            "Open System Settings on your Mac",
            "Go to Privacy & Security → Full Disk Access",
            "Add OpenBurnBar and toggle it on",
        )
    PhoneControlSystemPermissionKind.AUTOMATION -> {
        val target = bundleName ?: "the target app"
        listOf(
            "On your Mac, accept the Automation prompt for $target",
            "Or open Privacy & Security → Automation",
            "Allow OpenBurnBar to control $target",
        )
    }
}
