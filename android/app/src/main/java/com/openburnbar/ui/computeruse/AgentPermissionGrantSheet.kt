@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.AgentCapabilityGrantController
import com.openburnbar.data.computeruse.AgentCapabilityGrantState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentPermissionGrantSheet(runtime: String, threadId: String, onDismiss: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val controller =
        remember(context) {
            AgentCapabilityGrantController(context).also {
                BurnBarApplication.agentCapabilityGrantController = it
            }
        }
    val scope = rememberCoroutineScope()
    val receipts by AgentCapabilityGrantState.receipts.collectAsState()
    val receipt = receipts.values.firstOrNull { it.runtime == runtime && it.threadId == threadId }
    var workingPreset by remember { mutableStateOf<com.openburnbar.data.computeruse.AgentPermissionPreset?>(null) }
    var statusText by remember(receipt) {
        mutableStateOf(receipt?.message ?: receipt?.status?.wireValue ?: "Choose a permission level.")
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            AgentPermissionSheetHeader(runtime = runtime, threadId = threadId, onDismiss = onDismiss)

            Text(
                text = "Pick how much desktop power this one thread gets. Desktop, All, and YOLO require device unlock.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
            )

            AgentPermissionPresetFlowRow(
                target = AgentPermissionGrantTarget(runtime = runtime, threadId = threadId),
                controller = controller,
                scope = scope,
                receipt = receipt,
                workingPreset = workingPreset,
                callbacks =
                AgentPermissionGrantUiCallbacks(
                    onWorkingPresetChange = { workingPreset = it },
                    onStatusTextChange = { statusText = it },
                ),
            )

            AgentPermissionStatusFooter(statusText = statusText, receipt = receipt)

            Spacer(modifier = Modifier.height(18.dp))
        }
    }
}
