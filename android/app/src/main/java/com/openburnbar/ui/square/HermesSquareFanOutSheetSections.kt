@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.ui.components.ProviderLogo

@Composable
internal fun FanOutSheetBody(
    dispatchableIdentities: List<AgentIdentity>,
    uiState: FanOutSheetUiState,
    uiCallbacks: FanOutSheetUiCallbacks,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp)) {
        Text("Fan-out dispatch", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
        Spacer(modifier = Modifier.height(10.dp))
        FanOutMissionFields(
            title = uiState.title,
            prompt = uiState.prompt,
            onTitleChange = uiCallbacks.onTitleChange,
            onPromptChange = uiCallbacks.onPromptChange,
        )
        Spacer(modifier = Modifier.height(10.dp))
        FanOutRuntimePicker(
            dispatchableIdentities = dispatchableIdentities,
            selected = uiState.selected,
            onToggleRuntime = uiCallbacks.onToggleRuntime,
        )
        Spacer(modifier = Modifier.height(10.dp))
        FanOutPermissionToggles(
            commandsAllowed = uiState.commandsAllowed,
            fileEditsAllowed = uiState.fileEditsAllowed,
            onCommandsAllowedChange = uiCallbacks.onCommandsAllowedChange,
            onFileEditsAllowedChange = uiCallbacks.onFileEditsAllowedChange,
        )
        uiState.errorMessage?.let { msg ->
            Spacer(modifier = Modifier.height(8.dp))
            Text(msg, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
        }
        Spacer(modifier = Modifier.height(14.dp))
        FanOutDispatchButton(
            dispatching = uiState.dispatching,
            selectedCount = uiState.selected.size,
            enabled = !uiState.dispatching && uiState.prompt.trim().isNotBlank() && uiState.selected.size >= 2,
            onClick = uiCallbacks.onDispatch,
        )
    }
}

@Composable
internal fun FanOutMissionFields(
    title: String,
    prompt: String,
    onTitleChange: (String) -> Unit,
    onPromptChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = title,
        onValueChange = onTitleChange,
        placeholder = { Text("Title (optional)") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(modifier = Modifier.height(8.dp))
    OutlinedTextField(
        value = prompt,
        onValueChange = onPromptChange,
        placeholder = { Text("What should the fleet work on?") },
        modifier = Modifier.fillMaxWidth().height(110.dp),
    )
}

@Composable
internal fun FanOutRuntimePicker(
    dispatchableIdentities: List<AgentIdentity>,
    selected: List<String>,
    onToggleRuntime: (runtime: String, enabled: Boolean) -> Unit,
) {
    Text(
        "Runtimes (${selected.size}/${dispatchableIdentities.size})",
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.height(6.dp))
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth().height(180.dp),
    ) {
        items(dispatchableIdentities, key = { it.id }) { identity ->
            FanOutRuntimeRow(
                identity = identity,
                isOn = identity.runtimeID?.token?.let { selected.contains(it) } == true,
                canDisable = selected.size > 2,
                onToggle = { runtime, enabled -> onToggleRuntime(runtime, enabled) },
            )
        }
    }
}

@Composable
internal fun FanOutRuntimeRow(
    identity: AgentIdentity,
    isOn: Boolean,
    canDisable: Boolean,
    onToggle: (runtime: String, enabled: Boolean) -> Unit,
) {
    val runtime = identity.runtimeID?.token ?: return
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            if (identity.runtimeID != null) {
                ProviderLogo(runtime = identity.runtimeID, size = 22.dp)
            } else {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier =
                    Modifier
                        .size(22.dp)
                        .clip(RoundedCornerShape(50))
                        .background(hexColor(identity.paletteHex)),
                ) {
                    Text(
                        identity.glyph,
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                identity.displayName,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Switch(
                checked = isOn,
                onCheckedChange = { newOn ->
                    if (newOn) {
                        onToggle(runtime, true)
                    } else if (canDisable) {
                        onToggle(runtime, false)
                    }
                },
            )
        }
    }
}

@Composable
internal fun FanOutPermissionToggles(
    commandsAllowed: Boolean,
    fileEditsAllowed: Boolean,
    onCommandsAllowedChange: (Boolean) -> Unit,
    onFileEditsAllowedChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Switch(checked = commandsAllowed, onCheckedChange = onCommandsAllowedChange)
        Spacer(modifier = Modifier.width(6.dp))
        Text("Allow shell commands", fontSize = 12.sp)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Switch(checked = fileEditsAllowed, onCheckedChange = onFileEditsAllowedChange)
        Spacer(modifier = Modifier.width(6.dp))
        Text("Allow file edits", fontSize = 12.sp)
    }
}

@Composable
internal fun FanOutDispatchButton(
    dispatching: Boolean,
    selectedCount: Int,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (dispatching) {
            CircularProgressIndicator(
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
                color = MaterialTheme.colorScheme.onPrimary,
            )
        } else {
            Icon(Icons.Filled.Bolt, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text("Dispatch to $selectedCount runtimes")
        }
    }
}
