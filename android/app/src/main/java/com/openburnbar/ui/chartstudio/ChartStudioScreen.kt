package com.openburnbar.ui.chartstudio

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.theme.AuroraColors

/**
 * Top-level Chart Studio surface — fullscreen-only, hosted by the nav scaffold
 * inside an `AnimatedVisibility` that slides from the bottom.
 */
@Composable
fun ChartStudioScreen(digest: TrendDataDigest, hermes: HermesService, onClose: () -> Unit, onMinimize: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val state = rememberChartStudioState()
    val connection by hermes.selectedConnection.collectAsState()
    val canvases by ChartStudioCanvasStore.canvases.collectAsState()

    LaunchedEffect(context) { ChartStudioCanvasStore.bind(context) }

    val bridge = remember(connection) { ChartStudioHermesBridge(connection = connection) }
    val scope = rememberCoroutineScope()

    fun submit(prompt: String) {
        launchChartStudioSubmit(
            context = context,
            scope = scope,
            digest = digest,
            bridge = bridge,
            state = state,
            prompt = prompt,
        )
    }

    Box(modifier = modifier.fillMaxSize().background(AuroraColors.darkBackground)) {
        AuroraBackdrop()

        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            HeaderBar(
                connection = connection,
                isStreaming = state.isStreaming,
                onMinimize = onMinimize,
                onClose = onClose,
            )

            Box(modifier = Modifier.weight(1f)) {
                ChartStudioScrollBody(
                    digest = digest,
                    state = state,
                    canvases = canvases,
                    onSubmit = ::submit,
                )
            }

            ComposerBar(
                state = state,
                onSubmit = ::submit,
                onStop = { stopChartStudioStream(state) },
            )
        }
    }
}

@Composable
fun ChartStudioOverlay(hermes: HermesService, modifier: Modifier = Modifier) {
    val mode by rememberChartStudioMode()
    val snapshot by rememberChartStudioSnapshot()
    rememberChartStudioFabBinding()

    AnimatedVisibility(
        visible = mode == ChartStudioPresenter.Mode.Fullscreen && snapshot != null,
        enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
        exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
        modifier = modifier.fillMaxSize(),
    ) {
        snapshot?.let { snap ->
            ChartStudioScreen(
                digest = snap.digest,
                hermes = hermes,
                onClose = { ChartStudioPresenter.dismiss() },
                onMinimize = { ChartStudioPresenter.minimize() },
            )
        }
    }

    AnimatedVisibility(
        visible = mode == ChartStudioPresenter.Mode.Minimized,
        enter = fadeIn() + slideInVertically(initialOffsetY = { it / 2 }),
        exit = fadeOut() + slideOutVertically(targetOffsetY = { it / 2 }),
        modifier = modifier.fillMaxSize(),
    ) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(bottom = 96.dp, end = 16.dp),
            contentAlignment = Alignment.BottomEnd,
        ) {
            ChartStudioFab()
        }
    }
}
