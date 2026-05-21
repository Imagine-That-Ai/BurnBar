package com.openburnbar.ui.media

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraShadows
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
    val phase by pipeline.phase.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    val statusText = when (val currentPhase = phase) {
        VideoReceivePipeline.Phase.Idle -> "Preparing decoder..."
        is VideoReceivePipeline.Phase.Running ->
            if (stats.queuedFrameCount == 0L) "Waiting for Mac video..." else null
        is VideoReceivePipeline.Phase.Failed -> "Decoder unavailable: ${currentPhase.reason}"
        VideoReceivePipeline.Phase.Stopped -> "Screen share stopped"
    }

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
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                }
            },
        )

        // Frosted-glass loading/stopped panel with custom rotating golden loader
        statusText?.let { message ->
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .width(280.dp)
                    .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.35f, shadow = AuroraShadows.large)
                    .padding(24.dp),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    val isLoading = message.contains("Preparing") || message.contains("Waiting")
                    if (isLoading) {
                        // Beautiful rotating golden loader ring
                        val infiniteTransition = rememberInfiniteTransition(label = "loader")
                        val rotation by infiniteTransition.animateFloat(
                            initialValue = 0f,
                            targetValue = 360f,
                            animationSpec = infiniteRepeatable(
                                animation = tween(1000, easing = LinearEasing),
                                repeatMode = RepeatMode.Restart
                            ),
                            label = "rotation"
                        )
                        Canvas(modifier = Modifier.size(36.dp).graphicsLayer { rotationZ = rotation }) {
                            drawArc(
                                color = AuroraColors.amber,
                                startAngle = 0f,
                                sweepAngle = 270f,
                                useCenter = false,
                                style = androidx.compose.ui.graphics.drawscope.Stroke(
                                    width = 3.dp.toPx(),
                                    cap = androidx.compose.ui.graphics.StrokeCap.Round
                                )
                            )
                        }
                    } else {
                        // Connection/stopped icon
                        Icon(
                            imageVector = Icons.Filled.Computer,
                            contentDescription = null,
                            tint = if (message.contains("unavailable")) AuroraColors.errorDark else AuroraColors.hermesMercury,
                            modifier = Modifier.size(36.dp)
                        )
                    }
                    Text(
                        text = message,
                        color = Color.White,
                        style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                        textAlign = TextAlign.Center
                    )
                }
            }
        }

        // Highly polished diagnostic developer HUD stats overlay
        if (statsVisible) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
                    .width(200.dp)
                    .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.35f, shadow = AuroraShadows.subtle)
                    .padding(12.dp)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "MERCURY STREAM STATS",
                        color = AuroraColors.hermesMercury,
                        style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                    )
                    
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(Color.White.copy(alpha = 0.15f))
                    )

                    // Stat Rows
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("RESOLUTION", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                        Text("${stats.widthPx}×${stats.heightPx}", style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("CODEC", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                        Text(stats.codecName.uppercase(), style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("BITRATE", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                        Text("%.2f Mbps".format(stats.bitsPerSecond / 1_000_000.0), style = AuroraType.monoTiny.copy(color = AuroraColors.successDark, fontWeight = FontWeight.Bold))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("FRAMES", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                        Text("${stats.queuedFrameCount}", style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("LATENCY", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                        Text("${stats.roundTripMillis} ms", style = AuroraType.monoTiny.copy(
                            color = if (stats.roundTripMillis > 150) AuroraColors.errorDark else AuroraColors.successDark,
                            fontWeight = FontWeight.Bold
                        ))
                    }
                }
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
