package com.openburnbar.data.hermes

import android.util.Log
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Transport selection for outbound Hermes chat sends. */
internal class HermesServiceMessageLaunch(
    private val service: HermesService,
    private val messageActions: HermesServiceMessageActions,
    private val scope: CoroutineScope,
) {
    fun launchDesktopAgentRelaySend(content: String, resolvedModelName: String, attachments: List<HermesAttachment>, conversationId: String?) {
        if (attachments.isNotEmpty()) {
            messageActions.appendAssistantError(
                "Desktop agent relay from Android accepts text prompts today. Remove attachments and try again.",
                resolvedModelName,
            )
            return
        }
        val resolvedConversationId = conversationId ?: return
        service.isStreamingInternal.value = true
        launchStreamingSend(resolvedModelName) {
            messageActions.streamDesktopAgentRelayCompletion(
                prompt = content,
                modelName = resolvedModelName,
                conversationId = resolvedConversationId,
            )
        }
    }

    fun launchSelectedConnectionSend(content: String, resolvedModelName: String, attachments: List<HermesAttachment>, conversationId: String?) {
        val selected = service.selectedConnectionInternal.value
        when (selected.mode) {
            HermesConnectionMode.RELAY_LINK -> launchRelaySend(selected, content, resolvedModelName, attachments, conversationId)
            else -> launchHttpSend(content, resolvedModelName, attachments, conversationId)
        }
    }

    private fun launchRelaySend(
        selected: HermesConnectionRecord,
        content: String,
        resolvedModelName: String,
        attachments: List<HermesAttachment>,
        conversationId: String?,
    ) {
        val descriptor =
            HermesServiceRelayDescriptorSupport.descriptorFor(selected)
                ?: run {
                    messageActions.appendAssistantError(
                        "This Hermes relay isn't usable yet. Sign in and refresh relay connections, then try again.",
                        resolvedModelName,
                    )
                    return
                }
        if (service.relayClientInternal == null) {
            messageActions.appendAssistantError(
                "This Hermes relay isn't usable yet. Sign in and refresh relay connections, then try again.",
                resolvedModelName,
            )
            return
        }
        service.isStreamingInternal.value = true
        launchStreamingSend(resolvedModelName) {
            messageActions.streamChatCompletionViaRelay(
                descriptor = descriptor,
                prompt = content,
                modelName = resolvedModelName,
                attachments = attachments,
                conversationId = conversationId,
            )
        }
    }

    private fun launchHttpSend(content: String, resolvedModelName: String, attachments: List<HermesAttachment>, conversationId: String?) {
        val endpoint =
            HermesServiceEndpointSupport.selectedEndpointURL(service.selectedConnectionInternal.value)
                ?: HermesServiceEndpointSupport.legacyEndpointURL(service.legacyConnectionInternal)
        if (endpoint == null) {
            messageActions.appendAssistantError("No HTTP Hermes endpoint is configured.", resolvedModelName)
            return
        }
        service.isStreamingInternal.value = true
        launchStreamingSend(resolvedModelName) {
            messageActions.streamHttpChatCompletion(
                endpoint = endpoint,
                content = content,
                resolvedModelName = resolvedModelName,
                attachments = attachments,
                conversationId = conversationId,
            )
        }
    }

    private fun launchStreamingSend(modelName: String, block: suspend () -> Unit) {
        scope.launch(sendFailureHandler(modelName)) {
            try {
                block()
            } finally {
                service.isStreamingInternal.value = false
            }
        }
    }

    private fun sendFailureHandler(modelName: String): CoroutineExceptionHandler = CoroutineExceptionHandler { _, error ->
        val message = error.hermesSendFailureMessage()
        runCatching { Log.e(TAG, "Hermes send failed: $message", error) }
        service.runtimeErrorTextInternal.value = message
        messageActions.appendAssistantError(message, modelName)
    }

    private fun Throwable.hermesSendFailureMessage(): String = message?.takeIf { it.isNotBlank() } ?: javaClass.simpleName

    private companion object {
        private const val TAG = "BurnBar"
    }
}
