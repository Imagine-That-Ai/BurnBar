package com.openburnbar.ui.square

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry

// MARK: - Agent Brand Forward Sheet (Android parity)
//
// Forwards the latest thread / mirrored session from the source agent to
// a destination agent. Keeps the iOS choice model: pick destination, add
// note, fire onForward.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentBrandForwardSheet(
    source: AgentIdentity,
    registry: AgentIdentityRegistry,
    onDismiss: () -> Unit,
    onForward: (destination: AgentIdentity, note: String) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf<AgentIdentity?>(null) }
    var note by remember { mutableStateOf("") }
    val candidates =
        remember(registry.identities, source.id) {
            registry.identities.filter { it.id != source.id }
        }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        ForwardSheetBody(
            source = source,
            form = ForwardSheetFormState(candidates = candidates, selected = selected, note = note),
            callbacks =
            ForwardSheetCallbacks(
                onSelect = { selected = it },
                onNoteChange = { note = it },
                onForward = { selected?.let { onForward(it, note) } },
            ),
        )
    }
}
