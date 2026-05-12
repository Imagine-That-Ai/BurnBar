package com.openburnbar.ui.chartstudio

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job

/**
 * Per-screen state holder for `ChartStudioScreen`. Mirrors the iOS `@State`
 * cluster (`prompt`, `streamingText`, `rendering`, `error`, `isStreaming`,
 * `lastSubmittedPrompt`) but as a single `Stable` class so the screen reads
 * exactly one state holder instead of re-creating six per recompose.
 */
@Stable
class ChartStudioState {
    var prompt by mutableStateOf("")
    var streamingText by mutableStateOf("")
    var rendering by mutableStateOf<ChartStudioRendering?>(null)
    var isStreaming by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var lastSubmittedPrompt by mutableStateOf<String?>(null)
    var streamJob: Job? = null

    val hasAIRendering: Boolean
        get() = rendering != null || isStreaming || error != null

    fun reset() {
        rendering = null
        streamingText = ""
        error = null
        isStreaming = false
        streamJob?.cancel()
        streamJob = null
    }
}

@Composable
fun rememberChartStudioState(): ChartStudioState = remember { ChartStudioState() }
