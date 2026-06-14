package com.openburnbar.ui.square

import android.speech.SpeechRecognizer
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentSubscriptionTopic
import com.openburnbar.data.square.AgentSubscriptionTopicStore
import com.openburnbar.data.square.SubscriptionCadence
import kotlinx.coroutines.CoroutineScope

sealed class SubscribeAction {
    data class Subscribe(val cadence: SubscriptionCadence, val deliveryMode: SkillRunDeliveryMode) : SubscribeAction()
    data class SetMuted(val muted: Boolean) : SubscribeAction()
    data class SetDeliveryMode(val deliveryMode: SkillRunDeliveryMode) : SubscribeAction()
    object Unsubscribe : SubscribeAction()
}

internal data class DispatchSheetFormState(
    val title: String,
    val prompt: String,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
    val dispatching: Boolean,
    val inlineError: String?,
)

internal data class DispatchSheetCallbacks(
    val onTitleChange: (String) -> Unit,
    val onPromptChange: (String) -> Unit,
    val onCommandsAllowedChange: (Boolean) -> Unit,
    val onFileEditsAllowedChange: (Boolean) -> Unit,
    val onDispatch: () -> Unit,
)

internal data class ForwardSheetFormState(
    val candidates: List<AgentIdentity> = emptyList(),
    val selected: AgentIdentity? = null,
    val note: String = "",
)

internal data class ForwardSheetCallbacks(
    val onSelect: (AgentIdentity) -> Unit,
    val onNoteChange: (String) -> Unit,
    val onForward: () -> Unit,
)

internal data class SubscribeSheetFormState(
    val existingTopic: com.openburnbar.data.square.AgentSubscriptionTopic?,
    val selectedCadence: com.openburnbar.data.square.SubscriptionCadence,
    val selectedDeliveryMode: com.openburnbar.data.assistants.SkillRunDeliveryMode,
    val muted: Boolean,
)

internal data class SubscribeSheetCallbacks(
    val onCadenceSelected: (com.openburnbar.data.square.SubscriptionCadence) -> Unit,
    val onDeliveryModeSelected: (com.openburnbar.data.assistants.SkillRunDeliveryMode) -> Unit,
    val onMutedChange: (Boolean) -> Unit,
    val onSubscribe: () -> Unit,
    val onUnsubscribe: () -> Unit,
)

internal data class AgentBrandZoneOverlayState(
    val showDispatch: Boolean,
    val showForward: Boolean,
    val showSubscribe: Boolean,
)

internal data class AgentBrandZoneOverlayCallbacks(
    val onDismissDispatch: () -> Unit,
    val onDismissForward: () -> Unit,
    val onDismissSubscribe: () -> Unit,
    val onDispatchResult: (String) -> Unit,
    val onForwardResult: (String) -> Unit,
    val onSubscribeResult: (String) -> Unit,
)

internal data class VoiceHoldToTalkCallbacks(
    val onListeningChange: (Boolean) -> Unit,
    val onTranscriptChange: (String) -> Unit,
    val onCaptureError: (String) -> Unit,
    val onCaptureStart: () -> Unit,
    val onReleaseWithTranscript: (String) -> Unit,
)

internal data class FanOutDispatchRequest(
    val title: String,
    val prompt: String,
    val selected: List<String>,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
)

internal data class FanOutDispatchCallbacks(
    val onDispatching: (Boolean) -> Unit,
    val onError: (String?) -> Unit,
    val onDispatched: (String) -> Unit,
    val onDismiss: () -> Unit,
)

internal data class VoiceSheetCaptureState(
    val listening: Boolean,
    val transcript: String,
    val permissionGranted: Boolean,
    val recognizer: SpeechRecognizer,
    val errorMessage: String?,
)

internal data class AgentBrandDispatchRunRequest(
    val identity: AgentIdentity,
    val runtimeToken: String?,
    val title: String,
    val prompt: String,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
)

internal data class AgentBrandDispatchRunCallbacks(
    val onDispatching: (Boolean) -> Unit,
    val onInlineError: (String?) -> Unit,
    val onResult: (String) -> Unit,
)

internal data class AgentBrandZoneMainColumnActions(
    val onComposeMission: () -> Unit,
    val onDispatch: () -> Unit,
    val onForward: () -> Unit,
    val onSubscribe: () -> Unit,
)

internal data class AgentBrandZoneOverlayContext(
    val identity: AgentIdentity,
    val registry: AgentIdentityRegistry,
    val missionHost: MobileMissionConsoleHost,
    val subscriptionStore: AgentSubscriptionTopicStore,
    val activeTopic: AgentSubscriptionTopic?,
    val coroutineScope: CoroutineScope,
)

internal data class FanOutSheetUiState(
    val title: String,
    val prompt: String,
    val selected: List<String>,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
    val dispatching: Boolean,
    val errorMessage: String?,
)

internal data class FanOutSheetUiCallbacks(
    val onTitleChange: (String) -> Unit,
    val onPromptChange: (String) -> Unit,
    val onToggleRuntime: (String, Boolean) -> Unit,
    val onCommandsAllowedChange: (Boolean) -> Unit,
    val onFileEditsAllowedChange: (Boolean) -> Unit,
    val onDispatch: () -> Unit,
)
