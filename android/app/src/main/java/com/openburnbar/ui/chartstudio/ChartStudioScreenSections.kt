@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import android.content.Context
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.ui.components.HapticBus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

internal fun launchChartStudioSubmit(
    context: Context,
    scope: CoroutineScope,
    digest: TrendDataDigest,
    bridge: ChartStudioHermesBridge,
    state: ChartStudioState,
    prompt: String,
): Job? {
    val trimmed = prompt.trim()
    if (trimmed.isEmpty() || state.isStreaming) return null
    HapticBus.light(context)
    state.reset()
    state.lastSubmittedPrompt = trimmed
    state.prompt = ""
    state.isStreaming = true
    state.streamJob?.cancel()
    return scope.launch {
        val systemPrompt = ChartStudioPromptEngine.systemPrompt(digest)
        bridge.stream(systemPrompt = systemPrompt, userPrompt = trimmed).collectLatest { event ->
            handleChartStudioStreamEvent(context, state, event)
        }
    }.also { state.streamJob = it }
}

private fun handleChartStudioStreamEvent(context: Context, state: ChartStudioState, event: ChartStudioHermesBridge.Event) {
    when (event) {
        is ChartStudioHermesBridge.Event.Partial -> {
            state.streamingText = event.text
        }
        is ChartStudioHermesBridge.Event.Completed -> {
            state.streamingText = event.text
            val rendering = ChartSpecRenderer.decode(event.text)
            state.rendering = rendering
            state.isStreaming = false
            if (rendering !is ChartStudioRendering.Error) {
                ChartStudioCanvasStore.add(context, state.lastSubmittedPrompt ?: "", event.text)
                HapticBus.success(context)
            } else {
                state.error = rendering.message
                HapticBus.warning(context)
            }
        }
        is ChartStudioHermesBridge.Event.Failed -> {
            state.error = event.message
            state.isStreaming = false
            HapticBus.error(context)
        }
    }
}

internal fun stopChartStudioStream(state: ChartStudioState) {
    state.streamJob?.cancel()
    state.isStreaming = false
}

internal fun replayChartStudioCanvas(state: ChartStudioState, canvas: ChartStudioCanvasStore.Canvas) {
    state.rendering = ChartSpecRenderer.decode(canvas.rawJson)
    state.error = null
    state.isStreaming = false
}

internal fun subtitleFor(connection: HermesConnectionRecord, isStreaming: Boolean): String = when {
    isStreaming -> "Drawing with ${connection.id}…"
    connection.endpointURL.isNullOrBlank() -> "Hermes offline — connect from Settings"
    else -> "${connection.id} · ask for any chart"
}
