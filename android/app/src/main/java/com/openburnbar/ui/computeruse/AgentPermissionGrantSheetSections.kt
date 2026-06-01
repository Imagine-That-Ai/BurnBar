@file:Suppress("MagicNumber", "LongParameterList")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.openburnbar.data.computeruse.AgentCapabilityGrantController
import com.openburnbar.data.computeruse.AgentPermissionPreset
import java.security.GeneralSecurityException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal data class AgentPermissionGrantTarget(
    val runtime: String,
    val threadId: String,
)

internal data class AgentPermissionGrantUiCallbacks(
    val onWorkingPresetChange: (AgentPermissionPreset?) -> Unit,
    val onStatusTextChange: (String) -> Unit,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AgentPermissionPresetFlowRow(
    target: AgentPermissionGrantTarget,
    controller: AgentCapabilityGrantController,
    scope: CoroutineScope,
    receipt: com.openburnbar.data.computeruse.AgentCapabilityGrantReceipt?,
    workingPreset: AgentPermissionPreset?,
    callbacks: AgentPermissionGrantUiCallbacks,
) {
    val context = LocalContext.current
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        AgentPermissionPreset.values().forEach { preset ->
            AgentPermissionPresetButton(
                preset = preset,
                selected = isPresetSelected(receipt, preset),
                isWorking = workingPreset == preset,
                enabled = workingPreset == null,
                onClick = {
                    grantAgentPermissionPreset(
                        context = context,
                        controller = controller,
                        scope = scope,
                        target = target,
                        preset = preset,
                        callbacks = callbacks,
                    )
                },
            )
        }
    }
}

@Composable
private fun AgentPermissionPresetButton(
    preset: AgentPermissionPreset,
    selected: Boolean,
    isWorking: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors =
        if (preset == AgentPermissionPreset.YOLO) {
            ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.error,
                contentColor = MaterialTheme.colorScheme.onError,
            )
        } else {
            ButtonDefaults.buttonColors()
        }
    if (selected) {
        Button(onClick = onClick, enabled = enabled, colors = colors) {
            PermissionButtonContent(preset = preset, isWorking = isWorking, selected = true)
        }
    } else {
        OutlinedButton(onClick = onClick, enabled = enabled) {
            PermissionButtonContent(preset = preset, isWorking = isWorking, selected = false)
        }
    }
}

private fun isPresetSelected(
    receipt: com.openburnbar.data.computeruse.AgentCapabilityGrantReceipt?,
    preset: AgentPermissionPreset,
): Boolean {
    return receipt?.capabilities?.sorted() == preset.capabilities.map { it.wireValue }.sorted() &&
        receipt.trustMode == preset.trustMode &&
        receipt.isActive
}

private fun grantAgentPermissionPreset(
    context: Context,
    controller: AgentCapabilityGrantController,
    scope: CoroutineScope,
    target: AgentPermissionGrantTarget,
    preset: AgentPermissionPreset,
    callbacks: AgentPermissionGrantUiCallbacks,
) {
    val activity = context.findFragmentActivity()
    if (activity == null) {
        callbacks.onStatusTextChange("OpenBurnBar needs an activity to unlock permissions.")
        return
    }
    callbacks.onWorkingPresetChange(preset)
    callbacks.onStatusTextChange("Signing ${preset.title}...")
    scope.launch {
        try {
            val next =
                controller.grant(
                    activity = activity,
                    runtime = target.runtime,
                    threadId = target.threadId,
                    preset = preset,
                )
            callbacks.onStatusTextChange(next.message ?: next.status.wireValue)
        } catch (error: GeneralSecurityException) {
            callbacks.onStatusTextChange(error.message ?: error::class.java.simpleName)
        } finally {
            callbacks.onWorkingPresetChange(null)
        }
    }
}

@Composable
internal fun PermissionButtonContent(preset: AgentPermissionPreset, isWorking: Boolean, selected: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (isWorking) {
            CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.height(16.dp))
        } else if (selected) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null)
        }
        Column {
            Text(preset.title, fontWeight = FontWeight.SemiBold)
            Text(preset.subtitle, fontSize = 11.sp)
        }
    }
}

@Composable
internal fun AgentPermissionStatusFooter(
    statusText: String,
    receipt: com.openburnbar.data.computeruse.AgentCapabilityGrantReceipt?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = statusText,
            color = MaterialTheme.colorScheme.primary,
            fontSize = 13.sp,
        )
        receipt?.takeIf { it.isActive }?.let { active ->
            AssistChip(
                onClick = {},
                label = {
                    Text("${active.capabilities.size} tools · ${active.trustMode}")
                },
                leadingIcon = {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null)
                },
            )
        }
    }
}

@Composable
internal fun AgentPermissionSheetHeader(runtime: String, threadId: String, onDismiss: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Security, contentDescription = null)
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
            Text(
                text = "Agent permissions",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = "${runtime.replaceFirstChar { it.uppercase() }} · ${threadId.take(8)}",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
            )
        }
        TextButton(onClick = onDismiss) { Text("Done") }
    }
}

internal tailrec fun Context.findFragmentActivity(): FragmentActivity? = when (this) {
    is FragmentActivity -> this
    is ContextWrapper -> baseContext.findFragmentActivity()
    else -> null
}
