package com.openburnbar.ui.square

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentSubscriptionTopic
import com.openburnbar.data.square.SubscriptionCadence

// MARK: - Agent Brand Subscribe Sheet (Android parity)
//
// Opt-in or update an `AgentSubscriptionTopic`. Same shape as the iOS
// surface — cadence picker + muted toggle + subscribe / unsubscribe.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentBrandSubscribeSheet(
    identity: AgentIdentity,
    existingTopic: AgentSubscriptionTopic?,
    onDismiss: () -> Unit,
    onAction: (SubscribeAction) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selectedCadence by remember(existingTopic) {
        mutableStateOf(existingTopic?.cadence ?: SubscriptionCadence.WEEKLY)
    }
    var muted by remember(existingTopic) { mutableStateOf(existingTopic?.muted ?: false) }

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
                if (existingTopic == null) "Subscribe to ${identity.displayName}" else "${identity.displayName} updates",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Cadence",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SubscriptionCadence.values().forEach { cadence ->
                    CadencePill(
                        label = cadence.displayLabel,
                        selected = cadence == selectedCadence,
                        onClick = { selectedCadence = cadence }
                    )
                }
            }
            if (existingTopic != null) {
                Spacer(modifier = Modifier.height(14.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = muted, onCheckedChange = {
                        muted = it
                        onAction(SubscribeAction.SetMuted(it))
                    })
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Mute notifications", fontSize = 12.sp)
                }
            }
            Spacer(modifier = Modifier.height(14.dp))
            Button(
                onClick = { onAction(SubscribeAction.Subscribe(selectedCadence)) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(if (existingTopic == null) "Subscribe" else "Update")
            }
            if (existingTopic != null) {
                Spacer(modifier = Modifier.height(6.dp))
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.error.copy(alpha = 0.14f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onAction(SubscribeAction.Unsubscribe) }
                ) {
                    Text(
                        "Unsubscribe",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.error,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 10.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun CadencePill(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.20f)
        else MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
        )
    }
}
