@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.openburnbar.data.media.VideoReceivePipeline

/**
 * Android Mercury screen-share viewer. 1:1 port of
 * `ScreenShareViewerView.swift` (iOS).
 */
@Composable
fun ScreenShareViewerScreen(
    pipeline: VideoReceivePipeline,
    modifier: Modifier = Modifier,
    options: ScreenShareViewerScreenOptions = ScreenShareViewerScreenOptions(),
) {
    val (inputs, route) = options.toScreenParams(pipeline)
    ScreenShareViewerScreenBody(modifier = modifier, inputs = inputs, route = route)
}
