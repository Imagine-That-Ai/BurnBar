package com.openburnbar.ui.computeruse

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.openburnbar.data.computeruse.AgentCapabilityGrantController
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.data.computeruse.AgentPermissionPreset
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AgentPermissionGrantSheet(
    runtime: String,
    threadId: String,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val controller = remember(context) {
        AgentCapabilityGrantController(context).also {
            com.openburnbar.BurnBarApplication.agentCapabilityGrantController = it
        }
    }
    val scope = rememberCoroutineScope()
    val receipts by AgentCapabilityGrantState.receipts.collectAsState()
    val receipt = receipts.values.firstOrNull { it.runtime == runtime && it.threadId == threadId }
    var workingPreset by remember { mutableStateOf<AgentPermissionPreset?>(null) }
    var statusText by remember(receipt) {
        mutableStateOf(receipt?.message ?: receipt?.status?.wireValue ?: "Choose a permission level.")
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
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

            Text(
                text = "Pick how much desktop power this one thread gets. Desktop, All, and YOLO require device unlock.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
            )

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                AgentPermissionPreset.values().forEach { preset ->
                    val selected = receipt?.capabilities?.sorted() == preset.capabilities.map { it.wireValue }.sorted() &&
                        receipt.trustMode == preset.trustMode &&
                        receipt.isActive
                    val isWorking = workingPreset == preset
                    val colors = if (preset == AgentPermissionPreset.YOLO) {
                        ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                            contentColor = MaterialTheme.colorScheme.onError,
                        )
                    } else {
                        ButtonDefaults.buttonColors()
                    }
                    val onClick: () -> Unit = {
                        val activity = context.findFragmentActivity()
                        if (activity == null) {
                            statusText = "OpenBurnBar needs an activity to unlock permissions."
                        } else {
                            workingPreset = preset
                            statusText = "Signing ${preset.title}..."
                            scope.launch {
                                try {
                                    val next = controller.grant(
                                        activity = activity,
                                        runtime = runtime,
                                        threadId = threadId,
                                        preset = preset,
                                    )
                                    statusText = next.message ?: next.status.wireValue
                                } catch (error: Throwable) {
                                    statusText = error.message ?: error::class.java.simpleName
                                } finally {
                                    workingPreset = null
                                }
                            }
                        }
                    }
                    if (selected) {
                        Button(onClick = onClick, enabled = workingPreset == null, colors = colors) {
                            PermissionButtonContent(preset = preset, isWorking = isWorking, selected = true)
                        }
                    } else {
                        OutlinedButton(onClick = onClick, enabled = workingPreset == null) {
                            PermissionButtonContent(preset = preset, isWorking = isWorking, selected = false)
                        }
                    }
                }
            }

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

            Spacer(modifier = Modifier.height(18.dp))
        }
    }
}

@Composable
private fun PermissionButtonContent(
    preset: AgentPermissionPreset,
    isWorking: Boolean,
    selected: Boolean,
) {
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

private tailrec fun Context.findFragmentActivity(): FragmentActivity? = when (this) {
    is FragmentActivity -> this
    is ContextWrapper -> baseContext.findFragmentActivity()
    else -> null
}
