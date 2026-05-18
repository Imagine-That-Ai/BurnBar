package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
    val candidates = remember(registry.identities, source.id) {
        registry.identities.filter { it.id != source.id }
    }

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
            Text(
                "Forward from ${source.displayName}",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Pick the destination agent. The thread context will be quoted as a system prompt addition on dispatch.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(12.dp))
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(220.dp)
            ) {
                items(candidates, key = { it.id }) { identity ->
                    val isSelected = selected?.id == identity.id
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
                        else MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { selected = identity }
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                        ) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(22.dp)
                                    .clip(RoundedCornerShape(50))
                                    .background(hexColor(identity.paletteHex))
                            ) {
                                Text(
                                    identity.glyph,
                                    color = Color.White,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Spacer(modifier = Modifier.width(10.dp))
                            Text(
                                identity.displayName,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = note,
                onValueChange = { note = it },
                placeholder = { Text("Add an optional note") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(90.dp)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = { selected?.let { onForward(it, note) } },
                enabled = selected != null,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Forward")
            }
        }
    }
}
