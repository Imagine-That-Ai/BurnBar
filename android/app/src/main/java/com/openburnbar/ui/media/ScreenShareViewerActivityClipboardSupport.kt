package com.openburnbar.ui.media

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import com.openburnbar.data.computeruse.PhoneControlClipboardAction
import com.openburnbar.data.computeruse.PhoneControlClipboardRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardStatus
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.launch

private const val CONTROL_STATUS_SHORT_MAX = 80

internal fun ScreenShareViewerActivity.sendClipboardRequest(action: HermesRealtimeRelayClipboardAction) {
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control to use Mac clipboard."
        return
    }
    controlScope.launch {
        runCatching {
            val requestId = UUID.randomUUID().toString()
            val request = buildPhoneControlClipboardRequest(action, requestId) ?: return@launch
            dispatchPhoneControlClipboardRequest(action, requestId, request)
        }.onFailure { error ->
            controlStatus.value =
                when {
                    error.message?.contains("not trusted", ignoreCase = true) == true ->
                        "Trust this Android to control Mac"
                    else -> error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Clipboard unavailable"
                }
            Log.w(ScreenShareViewerActivity.TAG, "Android remote clipboard request failed action=$action error=${error.message}", error)
        }
    }
}

private fun ScreenShareViewerActivity.buildPhoneControlClipboardRequest(
    action: HermesRealtimeRelayClipboardAction,
    requestId: String,
): PhoneControlClipboardRequest? = when (action) {
    HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> buildPasteToMacClipboardRequest(requestId)
    HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC ->
        PhoneControlClipboardRequest(
            requestId = requestId,
            action = PhoneControlClipboardAction.GRAB_FROM_MAC,
            contentType = ScreenShareViewerActivity.REMOTE_CLIPBOARD_CONTENT_TYPE,
            text = null,
            maxBytes = ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES,
        )
}

private fun ScreenShareViewerActivity.buildPasteToMacClipboardRequest(requestId: String): PhoneControlClipboardRequest? {
    val text = readLocalClipboardText()?.takeIf { it.isNotEmpty() }
    if (text == null) {
        controlStatus.value = "Clipboard empty"
        return null
    }
    val byteCount = text.toByteArray(Charsets.UTF_8).size
    if (byteCount > ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES) {
        controlStatus.value = "Clipboard too large"
        return null
    }
    return PhoneControlClipboardRequest(
        requestId = requestId,
        action = PhoneControlClipboardAction.PASTE_TO_MAC,
        contentType = ScreenShareViewerActivity.REMOTE_CLIPBOARD_CONTENT_TYPE,
        text = text,
        maxBytes = ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES,
    )
}

private suspend fun ScreenShareViewerActivity.dispatchPhoneControlClipboardRequest(
    action: HermesRealtimeRelayClipboardAction,
    requestId: String,
    request: PhoneControlClipboardRequest,
) {
    val sender = ensurePhoneControlSender()
    synchronized(pendingClipboardLock) {
        pendingClipboardRequests[requestId] = action
    }
    try {
        sender.send(request)
        controlStatus.value =
            when (action) {
                HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Sending clipboard"
                HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Requesting Mac clipboard"
            }
        Log.i(ScreenShareViewerActivity.TAG, "Android remote clipboard request sent action=$action requestId=$requestId")
    } catch (error: IOException) {
        synchronized(pendingClipboardLock) {
            pendingClipboardRequests.remove(requestId)
        }
        throw error
    }
}

internal fun ScreenShareViewerActivity.handleClipboardResponse(response: HermesRealtimeRelayClipboardResponse) {
    val matched =
        synchronized(pendingClipboardLock) {
            val expected = pendingClipboardRequests[response.requestId]
            if (expected == response.action) {
                pendingClipboardRequests.remove(response.requestId)
                true
            } else {
                false
            }
        }
    if (!matched) return

    if (response.status == HermesRealtimeRelayClipboardStatus.ACCEPTED &&
        response.action == HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC
    ) {
        val text = response.text.orEmpty()
        if (text.isNotEmpty()) {
            writeLocalClipboardText(text)
        }
    }
    controlStatus.value = clipboardStatusMessage(response)
}

internal fun ScreenShareViewerActivity.clipboardStatusMessage(response: HermesRealtimeRelayClipboardResponse): String = when (response.status) {
    HermesRealtimeRelayClipboardStatus.ACCEPTED ->
        when (response.action) {
            HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Pasted to Mac"
            HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Mac clipboard copied"
        }
    HermesRealtimeRelayClipboardStatus.EMPTY -> "Clipboard empty"
    HermesRealtimeRelayClipboardStatus.DENIED -> "Mac denied clipboard"
    HermesRealtimeRelayClipboardStatus.TOO_LARGE -> "Clipboard too large"
    HermesRealtimeRelayClipboardStatus.UNSUPPORTED -> "Mac denied clipboard"
    HermesRealtimeRelayClipboardStatus.ERROR -> "Mac denied clipboard"
}

internal fun ScreenShareViewerActivity.readLocalClipboardText(): String? {
    val clipboard =
        getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
    return firstPlainTextClipboardItem(clipboard.primaryClip)
}

internal fun ScreenShareViewerActivity.writeLocalClipboardText(text: String) {
    val clipboard =
        getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("Mac clipboard", text))
}

internal fun firstPlainTextClipboardItem(clip: ClipData?): String? {
    if (clip == null || clip.itemCount <= 0) return null
    if (!clip.description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) return null
    return clip.getItemAt(0).text?.toString()
}
