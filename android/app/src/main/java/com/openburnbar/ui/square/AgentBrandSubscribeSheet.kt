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
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentSubscriptionTopic
import com.openburnbar.data.square.SubscriptionCadence

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
    var selectedDeliveryMode by remember(existingTopic) {
        mutableStateOf(existingTopic?.deliveryMode ?: SkillRunDeliveryMode.ACTION_ONLY)
    }
    var muted by remember(existingTopic) { mutableStateOf(existingTopic?.muted ?: false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        SubscribeSheetBody(
            identity = identity,
            form =
            SubscribeSheetFormState(
                existingTopic = existingTopic,
                selectedCadence = selectedCadence,
                selectedDeliveryMode = selectedDeliveryMode,
                muted = muted,
            ),
            callbacks =
            SubscribeSheetCallbacks(
                onCadenceSelected = { selectedCadence = it },
                onDeliveryModeSelected = { mode ->
                    selectedDeliveryMode = mode
                    if (existingTopic != null) onAction(SubscribeAction.SetDeliveryMode(mode))
                },
                onMutedChange = {
                    muted = it
                    selectedDeliveryMode = if (it) SkillRunDeliveryMode.MUTED else SkillRunDeliveryMode.ACTION_ONLY
                    if (existingTopic != null) onAction(SubscribeAction.SetMuted(it))
                },
                onSubscribe = { onAction(SubscribeAction.Subscribe(selectedCadence, selectedDeliveryMode)) },
                onUnsubscribe = { onAction(SubscribeAction.Unsubscribe) },
            ),
        )
    }
}
