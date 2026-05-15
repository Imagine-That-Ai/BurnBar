package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.DispatchException
import com.openburnbar.data.square.AgentIdentityRegistry
import kotlinx.coroutines.launch

// MARK: - Fan-out composer (Hermes Square §6.4)
//
// Android parity of the iOS `FanOutComposerSheet`. Picks 2–5 runtimes,
// types a brief, fires `CLIAgentMissionDispatcher.dispatchFanOut`.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareFanOutSheet(
    registry: AgentIdentityRegistry,
    onDispatched: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    val selected = remember { mutableStateListOf("claude", "codex", "hermes") }
    var dispatching by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }

    val dispatchableIdentities = registry.identities.filter { it.runtimeID != null }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Text("Fan-out dispatch",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface)
            Spacer(modifier = Modifier.height(10.dp))

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
                placeholder = { Text("What should the fleet work on?") },
                modifier = Modifier.fillMaxWidth().height(110.dp)
            )

            Spacer(modifier = Modifier.height(10.dp))
            Text("Runtimes (${selected.size}/${dispatchableIdentities.size})",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.height(6.dp))

            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxWidth().height(180.dp)
            ) {
                items(dispatchableIdentities, key = { it.id }) { identity ->
                    val runtime = identity.runtimeID?.token ?: return@items
                    val isOn = selected.contains(runtime)
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                        ) {
                            androidx.compose.foundation.layout.Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(22.dp)
                                    .clip(RoundedCornerShape(50))
                                    .androidx_background(hexColor(identity.paletteHex))
                            ) {
                                Text(identity.glyph, color = Color.White,
                                    fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                            Spacer(modifier = Modifier.width(10.dp))
                            Text(identity.displayName,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f))
                            Switch(
                                checked = isOn,
                                onCheckedChange = { newOn ->
                                    if (newOn) selected.add(runtime)
                                    else if (selected.size > 2) selected.remove(runtime)
                                }
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = commandsAllowed, onCheckedChange = { commandsAllowed = it })
                Spacer(modifier = Modifier.width(6.dp))
                Text("Allow shell commands", fontSize = 12.sp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = fileEditsAllowed, onCheckedChange = { fileEditsAllowed = it })
                Spacer(modifier = Modifier.width(6.dp))
                Text("Allow file edits", fontSize = 12.sp)
            }

            errorMessage?.let { msg ->
                Spacer(modifier = Modifier.height(8.dp))
                Text(msg, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
            }

            Spacer(modifier = Modifier.height(14.dp))
            Button(
                onClick = {
                    if (prompt.trim().isBlank() || selected.size < 2) return@Button
                    dispatching = true
                    errorMessage = null
                    scope.launch {
                        try {
                            val result = CLIAgentMissionDispatcher().dispatchFanOut(
                                title = title,
                                prompt = prompt,
                                missionKind = "diligence",
                                runtimeTokens = selected.toList(),
                                commandsAllowed = commandsAllowed,
                                fileEditsAllowed = fileEditsAllowed,
                            )
                            onDispatched(result.groupID)
                            onDismiss()
                        } catch (e: DispatchException) {
                            errorMessage = e.message
                        } catch (e: Exception) {
                            errorMessage = e.localizedMessage ?: "Dispatch failed."
                        } finally {
                            dispatching = false
                        }
                    }
                },
                enabled = !dispatching && prompt.trim().isNotBlank() && selected.size >= 2,
                modifier = Modifier.fillMaxWidth()
            ) {
                if (dispatching) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(18.dp),
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                } else {
                    Icon(Icons.Filled.Bolt, contentDescription = null,
                        modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Dispatch to ${selected.size} runtimes")
                }
            }
        }
    }
}

// Compose's `background` modifier extension lives in foundation; thin
// alias so the avatar block reads like a single rounded fill.
private fun Modifier.androidx_background(color: Color): Modifier =
    this.background(color)
