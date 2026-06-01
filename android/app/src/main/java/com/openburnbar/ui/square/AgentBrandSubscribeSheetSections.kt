@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.SubscriptionCadence

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SubscribeSheetBody(identity: AgentIdentity, form: SubscribeSheetFormState, callbacks: SubscribeSheetCallbacks) {
    val existingTopic = form.existingTopic
    val selectedCadence = form.selectedCadence
    val selectedDeliveryMode = form.selectedDeliveryMode
    val muted = form.muted
    val onCadenceSelected = callbacks.onCadenceSelected
    val onDeliveryModeSelected = callbacks.onDeliveryModeSelected
    val onMutedChange = callbacks.onMutedChange
    val onSubscribe = callbacks.onSubscribe
    val onUnsubscribe = callbacks.onUnsubscribe
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
    ) {
        Text(
            if (existingTopic == null) "Subscribe to ${identity.displayName}" else "${identity.displayName} updates",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(8.dp))
        SubscribeCadencePicker(selectedCadence = selectedCadence, onCadenceSelected = onCadenceSelected)
        Spacer(modifier = Modifier.height(14.dp))
        SubscribeDeliveryPicker(
            selectedDeliveryMode = selectedDeliveryMode,
            onDeliveryModeSelected = onDeliveryModeSelected,
            onMutedChange = onMutedChange,
        )
        if (existingTopic != null) {
            Spacer(modifier = Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = muted, onCheckedChange = onMutedChange)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Mute notifications", fontSize = 12.sp)
            }
        }
        Spacer(modifier = Modifier.height(14.dp))
        Button(onClick = onSubscribe, modifier = Modifier.fillMaxWidth()) {
            Text(if (existingTopic == null) "Subscribe" else "Update")
        }
        if (existingTopic != null) {
            Spacer(modifier = Modifier.height(6.dp))
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.error.copy(alpha = 0.14f),
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable(onClick = onUnsubscribe),
            ) {
                Text(
                    "Unsubscribe",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.error,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SubscribeCadencePicker(selectedCadence: SubscriptionCadence, onCadenceSelected: (SubscriptionCadence) -> Unit) {
    Text("Cadence", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(modifier = Modifier.height(6.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SubscriptionCadence.values().forEach { cadence ->
            CadencePill(label = cadence.displayLabel, selected = cadence == selectedCadence, onClick = { onCadenceSelected(cadence) })
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SubscribeDeliveryPicker(
    selectedDeliveryMode: SkillRunDeliveryMode,
    onDeliveryModeSelected: (SkillRunDeliveryMode) -> Unit,
    onMutedChange: (Boolean) -> Unit,
) {
    Text("Delivery", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(modifier = Modifier.height(6.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SkillRunDeliveryMode.values().forEach { mode ->
            CadencePill(
                label = mode.displayLabel,
                selected = mode == selectedDeliveryMode,
                onClick = {
                    onDeliveryModeSelected(mode)
                    onMutedChange(mode == SkillRunDeliveryMode.MUTED)
                },
            )
        }
    }
}

@Composable
internal fun CadencePill(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color =
        if (selected) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.20f)
        } else {
            MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
        },
        modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable(onClick = onClick),
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}
