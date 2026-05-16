package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentDispatchTransport
import com.openburnbar.data.square.AgentIdentity
import kotlinx.coroutines.launch

// MARK: - Agent Brand Dispatch Sheet (Android parity)
//
// Surface for dispatching a single mission targeted at this brand-zone
// agent. Mirrors the iOS `AgentBrandDispatchSheet` (essentials only —
// kind / depth / approvals pickers compress into Allow Shell + Allow
// Files toggles for parity with the Fan-out sheet).

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentBrandDispatchSheet(
    identity: AgentIdentity,
    missionHost: MobileMissionConsoleHost,
    onDismiss: () -> Unit,
    onResult: (String) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    var dispatching by remember { mutableStateOf(false) }
    var inlineError by remember { mutableStateOf<String?>(null) }

    val runtimeToken = remember(identity) {
        identity.runtimeID?.token
            ?: (identity.dispatchTransport as? AgentDispatchTransport.MacRelay)?.runtime
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 18.dp)
        ) {
            Text(
                "Dispatch to ${identity.displayName}",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                placeholder = { Text("Title (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = prompt,
                onValueChange = { prompt = it },
                placeholder = { Text("What should ${identity.displayName} do?") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Switch(checked = commandsAllowed, onCheckedChange = { commandsAllowed = it })
                Spacer(modifier = Modifier.width(8.dp))
                Text("Allow shell commands", fontSize = 12.sp)
            }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Switch(checked = fileEditsAllowed, onCheckedChange = { fileEditsAllowed = it })
                Spacer(modifier = Modifier.width(8.dp))
                Text("Allow file edits", fontSize = 12.sp)
            }
            inlineError?.let { msg ->
                Spacer(modifier = Modifier.height(8.dp))
                Text(msg, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
            }
            Spacer(modifier = Modifier.height(14.dp))
            Button(
                onClick = {
                    if (prompt.isBlank()) return@Button
                    if (runtimeToken == null) {
                        inlineError = "This agent doesn't expose a dispatch runtime."
                        return@Button
                    }
                    dispatching = true
                    inlineError = null
                    scope.launch {
                        val id = missionHost.dispatch(
                            title = title,
                            prompt = prompt,
                            missionKind = "diligence",
                            runtimeID = runtimeToken,
                            commandsAllowed = commandsAllowed,
                            fileEditsAllowed = fileEditsAllowed,
                        )
                        dispatching = false
                        if (id != null) {
                            onResult("Dispatched to ${identity.displayName} (mission $id).")
                        } else {
                            inlineError = "Dispatch failed."
                        }
                    }
                },
                enabled = !dispatching && prompt.trim().isNotBlank(),
                modifier = Modifier.fillMaxWidth()
            ) {
                if (dispatching) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp),
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                } else {
                    Text("Dispatch")
                }
            }
        }
    }
}
