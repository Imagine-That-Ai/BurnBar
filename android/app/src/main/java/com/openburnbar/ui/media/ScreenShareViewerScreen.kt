package com.openburnbar.ui.media

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.data.media.VideoReceivePipeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * Android Mercury screen-share viewer. 1:1 port of
 * `ScreenShareViewerView.swift` (iOS).
 *
 * Full-bleed `SurfaceView` with a triple-tap toggle for the stats
 * overlay. The viewer hosts a `VideoReceivePipeline` and binds its
 * output surface to the surface view's holder. Picture-in-Picture is
 * handled by the host `ScreenShareViewerActivity` (manifest entry).
 */
@Composable
fun ScreenShareViewerScreen(
    pipeline: VideoReceivePipeline,
    modifier: Modifier = Modifier,
) {
    var statsVisible by remember { mutableStateOf(false) }
    var tapCount by remember { mutableStateOf(0) }
    var lastTapAt by remember { mutableStateOf(0L) }
    val stats by pipeline.stats.collectAsState()
    val coroutineScope = rememberCoroutineScope()

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        if (event.changes.any { it.pressed }) {
                            val now = System.currentTimeMillis()
                            if (now - lastTapAt > 600) tapCount = 0
                            lastTapAt = now
                            tapCount += 1
                            if (tapCount >= 3) {
                                statsVisible = !statsVisible
                                tapCount = 0
                            }
                        }
                    }
                }
            },
        contentAlignment = Alignment.TopEnd,
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                }
            },
        )

        if (statsVisible) {
            Column(
                modifier = Modifier
                    .padding(12.dp)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.End,
            ) {
                Text(
                    text = "${stats.widthPx}×${stats.heightPx}",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White,
                )
                Text(
                    text = "${stats.codecName} · ${"%.2f Mbps".format(stats.bitsPerSecond / 1_000_000.0)}",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White,
                )
                Text(
                    text = "RTT ${stats.roundTripMillis} ms",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White,
                )
            }
        }
    }

    DisposableEffect(pipeline) {
        onDispose {
            // Best-effort tear-down when the composable leaves composition.
            runBlocking { pipeline.stop() }
        }
    }
}

private class SurfaceCallback(
    private val pipeline: VideoReceivePipeline,
    private val scope: CoroutineScope,
) : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
        scope.launch { pipeline.start(holder.surface) }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        scope.launch { pipeline.stop() }
    }
}
