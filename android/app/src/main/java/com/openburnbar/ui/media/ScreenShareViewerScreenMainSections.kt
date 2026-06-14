// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import android.view.SurfaceView
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.data.media.VideoReceivePipeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

@Composable
internal fun rememberScreenShareViewerLocals(selectedDisplayId: String?): ScreenShareViewerLocals {
    val context = LocalContext.current
    val toolsCollapsed = rememberSaveable { mutableStateOf(false) }
    val fitName = rememberSaveable { mutableStateOf(ScreenMirrorFit.FIT.name) }
    val controlModeName = rememberSaveable { mutableStateOf(ScreenMirrorControlMode.VIEW.name) }
    val smartZoomModeName = rememberSaveable { mutableStateOf(SmartZoomMode.SMART.name) }
    val typingOpen = rememberSaveable { mutableStateOf(false) }
    val trayScale = rememberSaveable { mutableStateOf(1.0f) }
    val locals =
        remember(context, toolsCollapsed, fitName, controlModeName, smartZoomModeName, typingOpen, trayScale) {
            ScreenShareViewerLocals(
                context = context,
                toolsCollapsed = toolsCollapsed,
                fitName = fitName,
                controlModeName = controlModeName,
                smartZoomModeName = smartZoomModeName,
                typingOpen = typingOpen,
                trayScale = trayScale,
            )
        }
    LaunchedEffect(selectedDisplayId) {
        locals.syncActiveDisplayId(selectedDisplayId)
    }
    return locals
}

@Composable
internal fun ScreenShareViewerScreenBody(modifier: Modifier, inputs: ScreenShareViewerScreenInputs, route: ScreenShareViewerScreenRouteCallbacks) {
    val locals = rememberScreenShareViewerLocals(inputs.selectedDisplayId)
    val stats by inputs.pipeline.stats.collectAsState()
    val phase by inputs.pipeline.phase.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    val derived =
        screenShareViewerDerivedUi(
            fitName = locals.fitName.value,
            controlModeName = locals.controlModeName.value,
            smartZoomModeName = locals.smartZoomModeName.value,
            remoteUnlockState = inputs.remoteUnlockState,
            phase = phase,
            stats = stats,
            nowMillis = locals.nowMillis,
            lastPeerHeartbeatAtMillis = inputs.lastPeerHeartbeatAtMillis,
        )
    ScreenShareViewerLifecycleEffects(
        locals.lifecycleParams(
            pipeline = inputs.pipeline,
            inputs = inputs,
            route = route,
            derived = derived,
        ),
    )
    ScreenShareViewerScreenAnimatedMain(
        ScreenShareViewerAnimatedMainParams(
            modifier = modifier,
            inputs = inputs,
            route = route,
            locals = locals,
            derived = derived,
            stats = stats,
            phase = phase,
            coroutineScope = coroutineScope,
        ),
    )
}

@Composable
private fun ScreenShareViewerScreenAnimatedMain(params: ScreenShareViewerAnimatedMainParams) {
    val modifier = params.modifier
    val inputs = params.inputs
    val route = params.route
    val locals = params.locals
    val derived = params.derived
    val stats = params.stats
    val phase = params.phase
    val coroutineScope = params.coroutineScope
    val context = LocalContext.current
    val animatedScale by animateFloatAsState(
        targetValue = locals.smartZoomDecision.scale,
        animationSpec = spring<Float>(dampingRatio = Spring.DampingRatioLowBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "smartZoomScale",
    )
    val animatedTranslationX by animateFloatAsState(
        targetValue = locals.smartZoomDecision.translation.x,
        animationSpec = spring<Float>(dampingRatio = Spring.DampingRatioLowBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "smartZoomTranslationX",
    )
    val animatedTranslationY by animateFloatAsState(
        targetValue = locals.smartZoomDecision.translation.y,
        animationSpec = spring<Float>(dampingRatio = Spring.DampingRatioLowBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "smartZoomTranslationY",
    )
    ScreenShareViewerMainContent(
        modifier = modifier,
        pipeline = inputs.pipeline,
        coroutineScope = coroutineScope,
        uiState =
        locals.mainUiState(
            ScreenShareViewerMainUiStateBuildInput(
                derived = derived,
                inputs = inputs,
                stats = stats,
                phase = phase,
                animatedScale = animatedScale,
                animatedTranslationX = animatedTranslationX,
                animatedTranslationY = animatedTranslationY,
            ),
        ),
        uiCallbacks =
        screenShareViewerMainUiCallbacks(
            ScreenShareViewerMainUiCallbacksSource(
                route = route,
                context = context,
                latestFocusContext = inputs.latestFocusContext,
                smartZoomMode = derived.smartZoomMode,
                fit = derived.fit,
                aspect = derived.aspect,
                locals = locals,
            ),
        ),
    )
}

@Composable
private fun ScreenShareViewerAutoCollapseEffect(
    lastInteractionTime: Long,
    toolsCollapsed: Boolean,
    openGroup: MirrorControlGroup?,
    typingOpen: Boolean,
    onAutoCollapseTools: () -> Unit,
) {
    LaunchedEffect(lastInteractionTime, toolsCollapsed, openGroup, typingOpen) {
        if (!toolsCollapsed && openGroup == null && !typingOpen) {
            delay(2000)
            onAutoCollapseTools()
        }
    }
}

@Composable
private fun ScreenShareViewerSmartZoomFollowEffect(params: ScreenShareViewerSmartZoomFollowParams) {
    val latestFocusContext = params.latestFocusContext
    val smartZoomMode = params.smartZoomMode
    val activeDisplayId = params.activeDisplayId
    val aspect = params.aspect
    val fit = params.fit
    val surfaceLayoutSize = params.surfaceLayoutSize
    val smartZoomManualOverrideUntilMillis = params.smartZoomManualOverrideUntilMillis
    val smartZoomDecision = params.smartZoomDecision
    val onSmartZoomDecision = params.onSmartZoomDecision
    LaunchedEffect(latestFocusContext, smartZoomMode, activeDisplayId, aspect, fit, surfaceLayoutSize) {
        if (surfaceLayoutSize == IntSize.Zero) return@LaunchedEffect
        val bounds = ScreenMirrorInputPolicy.surfaceBounds(surfaceLayoutSize, fit, aspect) ?: return@LaunchedEffect
        val viewportSize = IntSize(bounds.width.toInt(), bounds.height.toInt())
        val contentRect = Rect(left = 0f, top = 0f, right = bounds.width, bottom = bounds.height)
        onSmartZoomDecision(
            ScreenShareSmartZoomReducer.reduce(
                viewport = ScreenShareSmartZoomReducer.SmartZoomViewport(
                    viewportSize = viewportSize,
                    contentRect = contentRect,
                    currentScale = smartZoomDecision.scale,
                    currentTranslation = smartZoomDecision.translation,
                ),
                inputs = ScreenShareSmartZoomReducer.SmartZoomReduceInputs(
                    context = latestFocusContext,
                    mode = smartZoomMode,
                    selectedDisplayId = activeDisplayId,
                    manualOverrideUntilMillis = smartZoomManualOverrideUntilMillis,
                    nowMillis = System.currentTimeMillis(),
                ),
            ),
        )
    }
}

@Composable
private fun ScreenShareViewerAutoTypeEffect(params: ScreenShareViewerAutoTypeParams) {
    val latestFocusContext = params.latestFocusContext
    val autoKeyboardOnTextFocus = params.autoKeyboardOnTextFocus
    val controlMode = params.controlMode
    val standardControlEnabled = params.standardControlEnabled
    val typingOpen = params.typingOpen
    val activeDisplayId = params.activeDisplayId
    val autoTypeManualDismissUntilMillis = params.autoTypeManualDismissUntilMillis
    val onTypingOpenChange = params.onTypingOpenChange
    val onControlModeNameChange = params.onControlModeNameChange
    LaunchedEffect(
        latestFocusContext,
        autoKeyboardOnTextFocus,
        controlMode,
        standardControlEnabled,
        typingOpen,
        activeDisplayId,
        autoTypeManualDismissUntilMillis,
    ) {
        val now = System.currentTimeMillis()
        val autoTypeInput = ScreenShareAutoTypeFollowPolicy.Input(
            autoKeyboardEnabled = autoKeyboardOnTextFocus,
            standardControlEnabled = standardControlEnabled,
            controlMode = controlMode,
            typingOpen = typingOpen,
            context = latestFocusContext,
            selectedDisplayId = activeDisplayId,
            manualDismissUntilMillis = autoTypeManualDismissUntilMillis,
            nowMillis = now,
        )
        when {
            ScreenShareAutoTypeFollowPolicy.shouldOpen(autoTypeInput) -> {
                onTypingOpenChange(true)
                if (controlMode == ScreenMirrorControlMode.VIEW) {
                    onControlModeNameChange(ScreenMirrorControlMode.TOUCH.name)
                }
            }
            typingOpen && ScreenShareAutoTypeFollowPolicy.shouldClose(autoTypeInput) -> onTypingOpenChange(false)
        }
    }
}

@Composable
private fun ScreenShareViewerPipelineClockEffects(params: ScreenShareViewerPipelineClockParams) {
    val pipeline = params.pipeline
    val onNowMillis = params.onNowMillis
    val streamNeedsRecovery = params.streamNeedsRecovery
    val nowMillis = params.nowMillis
    val lastAutomaticReconnectAtMillis = params.lastAutomaticReconnectAtMillis
    val onLastAutomaticReconnectAtMillis = params.onLastAutomaticReconnectAtMillis
    val onReconnect = params.onReconnect
    DisposableEffect(pipeline) { onDispose { runBlocking { pipeline.stop() } } }
    LaunchedEffect(Unit) {
        while (true) {
            onNowMillis(System.currentTimeMillis())
            delay(1_000)
        }
    }
    LaunchedEffect(streamNeedsRecovery, nowMillis) {
        if (!streamNeedsRecovery) return@LaunchedEffect
        if (nowMillis - lastAutomaticReconnectAtMillis < AUTO_RECOVERY_RETRY_MILLIS) return@LaunchedEffect
        onLastAutomaticReconnectAtMillis(nowMillis)
        onReconnect()
    }
}

@Composable
internal fun ScreenShareViewerLifecycleEffects(params: ScreenShareViewerLifecycleParams) {
    ScreenShareViewerAutoCollapseEffect(
        lastInteractionTime = params.lastInteractionTime,
        toolsCollapsed = params.toolsCollapsed,
        openGroup = params.openGroup,
        typingOpen = params.typingOpen,
        onAutoCollapseTools = params.onAutoCollapseTools,
    )
    ScreenShareViewerSmartZoomFollowEffect(params.smartZoomFollowParams())
    ScreenShareViewerAutoTypeEffect(params.autoTypeParams())
    ScreenShareViewerPipelineClockEffects(params.pipelineClockParams())
}

@Composable
internal fun ScreenShareViewerMainContent(
    modifier: Modifier,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    uiState: ScreenShareViewerMainUiState,
    uiCallbacks: ScreenShareViewerMainUiCallbacks,
) {
    val zoomHandlers =
        rememberScreenShareZoomHandlers(
            smartZoomDecision = uiState.smartZoomDecision,
            onSmartZoomDecision = uiCallbacks.onSmartZoomDecision,
            onSmartZoomManualOverride = uiCallbacks.onSmartZoomManualOverride,
            surfaceLayoutSize = uiState.surfaceLayoutSize,
            fit = uiState.fit,
            aspect = uiState.aspect,
        )

    Box(
        modifier =
        modifier
            .fillMaxSize()
            .background(Color.Black)
            .onSizeChanged(uiCallbacks.onSurfaceLayoutSize)
            .screenShareSmartZoomPinchModifier(
                fit = uiState.fit,
                aspect = uiState.aspect,
                smartZoomDecision = uiState.smartZoomDecision,
                onSmartZoomManualOverride = uiCallbacks.onSmartZoomManualOverride,
                onSmartZoomDecision = uiCallbacks.onSmartZoomDecision,
                onLastInteraction = uiCallbacks.onLastInteraction,
            ),
        contentAlignment = Alignment.Center,
    ) {
        ScreenShareViewerMainLayers(
            pipeline = pipeline,
            coroutineScope = coroutineScope,
            uiState = uiState,
            uiCallbacks = uiCallbacks,
            zoomHandlers = zoomHandlers,
        )
    }
}

@Composable
private fun BoxScope.ScreenShareViewerMainLayers(
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    uiState: ScreenShareViewerMainUiState,
    uiCallbacks: ScreenShareViewerMainUiCallbacks,
    zoomHandlers: ScreenShareZoomHandlers,
) {
    ScreenShareViewerVideoSurface(
        surfaceModifier =
        Modifier
            .screenMirrorSurface(fit = uiState.fit, aspect = uiState.aspect)
            .align(Alignment.Center)
            .graphicsLayer {
                scaleX = uiState.animatedScale
                scaleY = uiState.animatedScale
                translationX = uiState.animatedTranslationX
                translationY = uiState.animatedTranslationY
            },
        pipeline = pipeline,
        coroutineScope = coroutineScope,
        controlMode = uiState.controlMode,
        standardControlEnabled = uiState.standardControlEnabled,
    )

    ScreenShareViewerControlGestureLayer(
        uiState = uiState.toGestureUiState(),
        uiCallbacks = uiCallbacks.toGestureUiCallbacks(),
    )

    ScreenShareViewerModeOverlays(uiState.toModeOverlayParams(uiCallbacks))

    ScreenShareViewerStatusOverlays(uiState.toStatusOverlayParams(uiCallbacks))

    ScreenShareViewerToolsDockLayer(
        uiState = uiState,
        uiCallbacks = uiCallbacks,
        zoomHandlers = zoomHandlers,
    )
}

@Composable
private fun BoxScope.ScreenShareViewerToolsDockLayer(
    uiState: ScreenShareViewerMainUiState,
    uiCallbacks: ScreenShareViewerMainUiCallbacks,
    zoomHandlers: ScreenShareZoomHandlers,
) {
    ScreenMirrorToolsDock(
        modifier =
        Modifier
            .align(Alignment.BottomCenter)
            .padding(horizontal = 14.dp, vertical = 18.dp)
            .graphicsLayer {
                scaleX = uiState.trayScale
                scaleY = uiState.trayScale
                transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 1f)
            },
        state = mirrorDockUiStateFromMain(uiState),
        actions = mirrorDockActionsFromMain(uiState, uiCallbacks, zoomHandlers),
    )
}

@Composable
private fun ScreenShareViewerVideoSurface(
    surfaceModifier: Modifier,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    controlMode: ScreenMirrorControlMode,
    standardControlEnabled: Boolean,
) {
    Box(modifier = surfaceModifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                    setOnTouchListener { view, motionEvent -> false }
                    isClickable = false
                    isFocusable = false
                    isLongClickable = false
                }
            },
        )
        if (controlMode != ScreenMirrorControlMode.VIEW && standardControlEnabled) {
            ScreenMirrorInputOverlay()
        }
    }
}

@Composable
private fun ScreenShareViewerControlGestureLayer(uiState: ScreenShareViewerGestureUiState, uiCallbacks: ScreenShareViewerGestureUiCallbacks) {
    if (uiState.controlMode == ScreenMirrorControlMode.VIEW || !uiState.standardControlEnabled) return

    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .pointerInput(uiState.controlMode, uiState.fit, uiState.aspect) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
                        if (down != null) {
                            event.changes.forEach { it.consume() }
                            handleScreenShareGestureDown(
                                change = down,
                                scopeSize = size,
                                uiState = uiState,
                                uiCallbacks = uiCallbacks,
                            )
                        }
                        val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
                        if (up != null) {
                            event.changes.forEach { it.consume() }
                            handleScreenShareGestureUp(
                                change = up,
                                scopeSize = size,
                                uiState = uiState,
                                uiCallbacks = uiCallbacks,
                            )
                        }
                    }
                }
            },
    )
}

private fun handleScreenShareGestureDown(
    change: PointerInputChange,
    scopeSize: IntSize,
    uiState: ScreenShareViewerGestureUiState,
    uiCallbacks: ScreenShareViewerGestureUiCallbacks,
) {
    change.consume()
    val now = System.currentTimeMillis()
    uiCallbacks.onPressStartedAt(now)
    if (now - uiState.lastTapAt > 600) uiCallbacks.onTapCount(0)
    uiCallbacks.onLastTapAt(now)
    uiCallbacks.onTapCount(uiState.tapCount + 1)
    if (uiState.tapCount + 1 >= 3) {
        uiCallbacks.onStatsVisible(!uiState.statsVisible)
        uiCallbacks.onTapCount(0)
    }
    if (uiState.controlMode != ScreenMirrorControlMode.SCROLL) return
    ScreenMirrorInputPolicy.normalizedPoint(
        change.position,
        scopeSize,
        uiState.fit,
        uiState.aspect,
        uiState.smartZoomDecision.scale,
        uiState.smartZoomDecision.translation,
    )?.let { point ->
        uiCallbacks.onDragActive(true)
        uiCallbacks.onDragStartNormalized(point)
    }
}

private fun handleScreenShareGestureUp(
    change: PointerInputChange,
    scopeSize: IntSize,
    uiState: ScreenShareViewerGestureUiState,
    uiCallbacks: ScreenShareViewerGestureUiCallbacks,
) {
    change.consume()
    when (uiState.controlMode) {
        ScreenMirrorControlMode.TOUCH ->
            normalizedGesturePoint(change.position, scopeSize, uiState)?.let { point ->
                uiCallbacks.onTapNormalized(
                    point.first,
                    point.second,
                    ScreenMirrorInputPolicy.controlClickMouseButton(
                        heldMillis = System.currentTimeMillis() - uiState.pressStartedAt,
                    ),
                    uiState.activeDisplayId,
                )
            }
        ScreenMirrorControlMode.SCROLL -> {
            val start = uiState.dragStartNormalized
            val end = normalizedGesturePoint(change.position, scopeSize, uiState)
            if (uiState.dragActive && start != null && end != null) {
                uiCallbacks.onScrollDragNormalized(
                    start.first,
                    start.second,
                    end.first,
                    end.second,
                    uiState.activeDisplayId,
                )
            }
            uiCallbacks.onDragActive(false)
            uiCallbacks.onDragStartNormalized(null)
        }
        ScreenMirrorControlMode.COPILOT ->
            normalizedGesturePoint(change.position, scopeSize, uiState)?.let { point ->
                uiCallbacks.onCoPilotTargetChange(point)
                uiCallbacks.onCoPilotViewPointChange(change.position)
            }
        ScreenMirrorControlMode.TRACKPAD,
        ScreenMirrorControlMode.VIEW,
        -> Unit
    }
}

private fun normalizedGesturePoint(position: Offset, scopeSize: IntSize, uiState: ScreenShareViewerGestureUiState): Pair<Double, Double>? =
    ScreenMirrorInputPolicy.normalizedPoint(
        position,
        scopeSize,
        uiState.fit,
        uiState.aspect,
        uiState.smartZoomDecision.scale,
        uiState.smartZoomDecision.translation,
    )

@Composable
private fun BoxScope.ScreenShareViewerModeOverlays(params: ScreenShareViewerModeOverlayParams) {
    ScreenShareViewerCoPilotOverlays(params)
    ScreenShareViewerTrackpadOverlay(
        controlMode = params.controlMode,
        standardControlEnabled = params.standardControlEnabled,
        onPointerMove = params.onPointerMove,
        onPointerClick = params.onPointerClick,
    )
    ScreenShareViewerKeyboardOverlay(params)
}

@Composable
private fun BoxScope.ScreenShareViewerCoPilotOverlays(params: ScreenShareViewerModeOverlayParams) {
    if (params.controlMode != ScreenMirrorControlMode.COPILOT || !params.standardControlEnabled) return
    params.coPilotViewPoint?.let { pos -> CoPilotTargetReticle(position = pos) }
    params.coPilotTarget?.let { target ->
        CoPilotTargetOverlay(
            coPilotTarget = target,
            coPilotRuntime = params.coPilotRuntime,
            activeDisplayId = params.activeDisplayId,
            onRuntimeChange = params.onCoPilotRuntimeChange,
            onClearTarget = {
                params.onCoPilotTargetChange(null)
                params.onCoPilotViewPointChange(null)
            },
            onAgentContextTargetNormalized = params.onAgentContextTargetNormalized,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun BoxScope.ScreenShareViewerTrackpadOverlay(
    controlMode: ScreenMirrorControlMode,
    standardControlEnabled: Boolean,
    onPointerMove: (Double, Double) -> Unit,
    onPointerClick: (Int) -> Unit,
) {
    if (controlMode != ScreenMirrorControlMode.TRACKPAD || !standardControlEnabled) return
    ScreenMirrorTrackpadSurface(
        modifier =
        Modifier
            .align(Alignment.BottomEnd)
            .padding(end = 18.dp, bottom = 138.dp),
        onMove = { delta -> onPointerMove(delta.x.toDouble(), delta.y.toDouble()) },
        onClick = onPointerClick,
    )
}

@Composable
private fun BoxScope.ScreenShareViewerKeyboardOverlay(params: ScreenShareViewerModeOverlayParams) {
    if (!params.typingOpen || !params.standardControlEnabled) return
    RemoteKeyboardCaptureField(
        modifier =
        Modifier
            .align(Alignment.BottomStart)
            .padding(start = 1.dp, bottom = 1.dp),
        onText = params.onTypeText,
        onKey = { key -> params.onShortcut(key, emptyList()) },
        onDismiss = {
            params.onTypingOpenChange(false)
            val now = System.currentTimeMillis()
            if (
                params.autoKeyboardOnTextFocus &&
                ScreenShareAutoTypeFollowPolicy.hasActiveTextFocus(
                    context = params.latestFocusContext,
                    selectedDisplayId = params.activeDisplayId,
                    nowMillis = now,
                )
            ) {
                params.onAutoTypeManualDismissUntilMillis(
                    now + ScreenShareAutoTypeFollowPolicy.MANUAL_DISMISS_HOLD_MILLIS,
                )
            }
        },
    )
}

@Composable
private fun BoxScope.ScreenShareViewerStatusOverlays(params: ScreenShareViewerStatusOverlayParams) {
    params.statusText?.let { message ->
        FrostedGlassStatusPanel(message = message, modifier = Modifier.align(Alignment.Center))
    }

    if (params.statsVisible) {
        DiagnosticStatsHud(
            stats = params.stats,
            modifier = Modifier.align(Alignment.TopEnd).padding(16.dp),
        )
    }

    params.activeRemoteUnlockState?.let { state ->
        RemoteUnlockStatusPanel(
            state = state,
            modifier = Modifier.align(Alignment.TopCenter).padding(horizontal = 16.dp, vertical = 18.dp),
            savedCredentialAvailable = params.savedRemoteUnlockCredentialAvailable,
            callbacks =
            RemoteUnlockCallbacks(
                onReconnect = params.callbacks.onReconnect,
                onClose = params.callbacks.onClose,
                onSendPassword = params.callbacks.onSendRemoteUnlockPassword,
                onSavePassword = params.callbacks.onSaveRemoteUnlockPassword,
                onSendSavedPassword = params.callbacks.onSendSavedRemoteUnlockPassword,
                onDeleteSavedPassword = params.callbacks.onDeleteSavedRemoteUnlockPassword,
            ),
        )
    }
}

internal data class ScreenShareZoomHandlers(
    val onZoomIn: () -> Unit,
    val onZoomOut: () -> Unit,
    val onResetZoom: () -> Unit,
)

@Composable
private fun rememberScreenShareZoomHandlers(
    smartZoomDecision: ScreenShareSmartZoomDecision,
    onSmartZoomDecision: (ScreenShareSmartZoomDecision) -> Unit,
    onSmartZoomManualOverride: () -> Unit,
    surfaceLayoutSize: IntSize,
    fit: ScreenMirrorFit,
    aspect: Float,
): ScreenShareZoomHandlers {
    fun applyZoom(scaleMultiplier: Float) {
        onSmartZoomManualOverride()
        val currentScale = smartZoomDecision.scale
        val currentTranslation = smartZoomDecision.translation
        val newScale = (currentScale * scaleMultiplier).coerceIn(1f, 5f)
        val bounds = ScreenMirrorInputPolicy.surfaceBounds(surfaceLayoutSize, fit, aspect)
        if (bounds != null) {
            val halfW = bounds.width / 2f
            val halfH = bounds.height / 2f
            val maxTransX = halfW * (newScale - 1f)
            val maxTransY = halfH * (newScale - 1f)
            val translationMultiplier = if (scaleMultiplier > 1f) scaleMultiplier else 0.8f
            val newTranslationX = (currentTranslation.x * translationMultiplier).coerceIn(-maxTransX, maxTransX)
            val newTranslationY = (currentTranslation.y * translationMultiplier).coerceIn(-maxTransY, maxTransY)
            onSmartZoomDecision(
                ScreenShareSmartZoomDecision(
                    scale = newScale,
                    translation = Offset(newTranslationX, newTranslationY),
                    isAutoFollowing = false,
                ),
            )
        } else {
            onSmartZoomDecision(
                ScreenShareSmartZoomDecision(
                    scale = newScale,
                    translation = Offset.Zero,
                    isAutoFollowing = false,
                ),
            )
        }
    }

    return ScreenShareZoomHandlers(
        onZoomIn = { applyZoom(1.25f) },
        onZoomOut = { applyZoom(0.8f) },
        onResetZoom = {
            onSmartZoomManualOverride()
            onSmartZoomDecision(
                ScreenShareSmartZoomDecision(
                    scale = 1f,
                    translation = Offset.Zero,
                    isAutoFollowing = false,
                ),
            )
        },
    )
}

private fun ScreenShareViewerMainUiState.toGestureUiState(): ScreenShareViewerGestureUiState = ScreenShareViewerGestureUiState(
    controlMode = controlMode,
    fit = fit,
    aspect = aspect,
    standardControlEnabled = standardControlEnabled,
    smartZoomDecision = smartZoomDecision,
    activeDisplayId = activeDisplayId,
    tapCount = tapCount,
    lastTapAt = lastTapAt,
    dragActive = dragActive,
    dragStartNormalized = dragStartNormalized,
    pressStartedAt = pressStartedAt,
    statsVisible = statsVisible,
)

private fun ScreenShareViewerMainUiCallbacks.toGestureUiCallbacks(): ScreenShareViewerGestureUiCallbacks = ScreenShareViewerGestureUiCallbacks(
    onTapCount = onTapCount,
    onLastTapAt = onLastTapAt,
    onDragActive = onDragActive,
    onDragStartNormalized = onDragStartNormalized,
    onPressStartedAt = onPressStartedAt,
    onStatsVisible = onStatsVisible,
    onCoPilotTargetChange = onCoPilotTargetChange,
    onCoPilotViewPointChange = onCoPilotViewPointChange,
    onTapNormalized = onTapNormalized,
    onScrollDragNormalized = onScrollDragNormalized,
)

private fun ScreenShareViewerMainUiState.toModeOverlayParams(uiCallbacks: ScreenShareViewerMainUiCallbacks): ScreenShareViewerModeOverlayParams =
    ScreenShareViewerModeOverlayParams(
        controlMode = controlMode,
        standardControlEnabled = standardControlEnabled,
        coPilotViewPoint = coPilotViewPoint,
        coPilotTarget = coPilotTarget,
        coPilotRuntime = coPilotRuntime,
        activeDisplayId = activeDisplayId,
        onCoPilotRuntimeChange = uiCallbacks.onCoPilotRuntimeChange,
        onCoPilotTargetChange = uiCallbacks.onCoPilotTargetChange,
        onCoPilotViewPointChange = uiCallbacks.onCoPilotViewPointChange,
        onAgentContextTargetNormalized = uiCallbacks.onAgentContextTargetNormalized,
        typingOpen = typingOpen,
        onTypingOpenChange = uiCallbacks.onTypingOpenChange,
        autoKeyboardOnTextFocus = autoKeyboardOnTextFocus,
        autoTypeManualDismissUntilMillis = autoTypeManualDismissUntilMillis,
        onAutoTypeManualDismissUntilMillis = uiCallbacks.onAutoTypeManualDismissUntilMillis,
        latestFocusContext = latestFocusContext,
        onTypeText = uiCallbacks.onTypeText,
        onShortcut = uiCallbacks.onShortcut,
        onPointerMove = uiCallbacks.onPointerMove,
        onPointerClick = uiCallbacks.onPointerClick,
    )

private fun ScreenShareViewerMainUiState.toStatusOverlayParams(uiCallbacks: ScreenShareViewerMainUiCallbacks): ScreenShareViewerStatusOverlayParams =
    ScreenShareViewerStatusOverlayParams(
        statusText = statusText,
        statsVisible = statsVisible,
        stats = stats,
        activeRemoteUnlockState = activeRemoteUnlockState,
        savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable,
        callbacks =
        ScreenShareViewerStatusOverlayCallbacks(
            onReconnect = uiCallbacks.onReconnect,
            onClose = uiCallbacks.onClose,
            onSendRemoteUnlockPassword = uiCallbacks.onSendRemoteUnlockPassword,
            onSaveRemoteUnlockPassword = uiCallbacks.onSaveRemoteUnlockPassword,
            onSendSavedRemoteUnlockPassword = uiCallbacks.onSendSavedRemoteUnlockPassword,
            onDeleteSavedRemoteUnlockPassword = uiCallbacks.onDeleteSavedRemoteUnlockPassword,
        ),
    )

private fun mirrorDockUiStateFromMain(uiState: ScreenShareViewerMainUiState): MirrorDockUiState = buildMirrorDockUiState(uiState)

private fun mirrorDockActionsFromMain(
    uiState: ScreenShareViewerMainUiState,
    uiCallbacks: ScreenShareViewerMainUiCallbacks,
    zoomHandlers: ScreenShareZoomHandlers,
): MirrorDockActions = buildMirrorDockActions(MirrorDockActionsBuildInput(uiState, uiCallbacks, zoomHandlers))

private fun buildMirrorDockUiState(uiState: ScreenShareViewerMainUiState): MirrorDockUiState = MirrorDockUiState(
    collapsed = uiState.toolsCollapsed,
    openGroup = uiState.openGroup,
    fit = uiState.fit,
    controlMode = uiState.controlMode,
    typingOpen = uiState.typingOpen,
    statsVisible = uiState.statsVisible,
    phaseLabel =
    when (uiState.phase) {
        VideoReceivePipeline.Phase.Idle -> "Preparing"
        is VideoReceivePipeline.Phase.Running ->
            when {
                uiState.stats.queuedFrameCount == 0L -> "Waiting"
                uiState.streamNeedsRecovery -> "Recovering"
                else -> "Live"
            }
        is VideoReceivePipeline.Phase.Failed -> "Decoder"
        VideoReceivePipeline.Phase.Stopped -> "Stopped"
    },
    trayScale = uiState.trayScale,
    stats = uiState.stats,
    availableDisplays = uiState.availableDisplays,
    activeDisplayId = uiState.activeDisplayId,
    smartZoomMode = uiState.smartZoomMode,
    smartZoomAutoFollowing = uiState.smartZoomDecision.isAutoFollowing,
    autoKeyboardOnTextFocus = uiState.autoKeyboardOnTextFocus,
    controlStatus =
    if (uiState.activeRemoteUnlockState != null) {
        "Mac locked. Remote Unlock controls only."
    } else {
        uiState.controlStatus
    },
    isZoomed = uiState.smartZoomDecision.scale > 1.01f,
)

private fun mirrorDockSelectDisplayAction(uiCallbacks: ScreenShareViewerMainUiCallbacks): (String) -> Unit = { displayId ->
    uiCallbacks.onActiveDisplayId(displayId)
    uiCallbacks.onSelectDisplay(displayId)
}

private fun mirrorDockSelectSmartZoomModeAction(uiCallbacks: ScreenShareViewerMainUiCallbacks): (SmartZoomMode) -> Unit = { mode ->
    uiCallbacks.onSmartZoomModeName(mode.name)
    uiCallbacks.onSmartZoomManualOverrideUntilMillis(null)
    if (mode == SmartZoomMode.OFF) {
        uiCallbacks.onSmartZoomDecision(ScreenShareSmartZoomDecision.identity)
    } else {
        uiCallbacks.onRecomputeSmartZoom()
    }
}

private fun buildMirrorDockActions(input: MirrorDockActionsBuildInput): MirrorDockActions {
    val uiState = input.uiState
    val uiCallbacks = input.uiCallbacks
    val zoomHandlers = input.zoomHandlers
    val toolsCollapsed = uiState.toolsCollapsed
    val typingOpen = uiState.typingOpen
    val statsVisible = uiState.statsVisible
    val fit = uiState.fit
    val controlMode = uiState.controlMode
    val activeDisplayId = uiState.activeDisplayId
    return MirrorDockActions(
        onSelectDisplay = mirrorDockSelectDisplayAction(uiCallbacks),
        onTrayScaleChange = uiCallbacks.onTrayScale,
        onToggleCollapsed = {
            uiCallbacks.onToolsCollapsed(!toolsCollapsed)
            if (!toolsCollapsed) uiCallbacks.onOpenGroup(null)
        },
        onSelectGroup = uiCallbacks.onOpenGroup,
        onToggleStats = { uiCallbacks.onStatsVisible(!statsVisible) },
        onCycleFit = { uiCallbacks.onFitName(fit.next().name) },
        onCycleControlMode = { uiCallbacks.onControlModeName(controlMode.next().name) },
        onSelectSmartZoomMode = mirrorDockSelectSmartZoomModeAction(uiCallbacks),
        onSelectControlMode = { mode ->
            uiCallbacks.onControlModeName(mode.name)
            if (mode == ScreenMirrorControlMode.VIEW || mode == ScreenMirrorControlMode.COPILOT) {
                uiCallbacks.onTypingOpenChange(false)
            }
        },
        onAutoKeyboardOnTextFocusChange = uiCallbacks.onAutoKeyboardOnTextFocus,
        onToggleTyping = {
            uiCallbacks.onTypingOpenChange(!typingOpen)
            if (!typingOpen && controlMode == ScreenMirrorControlMode.VIEW) {
                uiCallbacks.onControlModeName(ScreenMirrorControlMode.TOUCH.name)
            }
        },
        onScrollUp = { uiCallbacks.onScrollNormalized(-0.16, activeDisplayId) },
        onScrollDown = { uiCallbacks.onScrollNormalized(0.16, activeDisplayId) },
        onEscape = { uiCallbacks.onShortcut("escape", emptyList()) },
        onCommandTab = { uiCallbacks.onShortcut("tab", listOf("command")) },
        onPasteClipboardToMac = uiCallbacks.onPasteClipboardToMac,
        onGrabClipboardFromMac = uiCallbacks.onGrabClipboardFromMac,
        onPanic = uiCallbacks.onPanic,
        onTrustControlDevice = uiCallbacks.onTrustControlDevice,
        onReconnect = uiCallbacks.onReconnect,
        onEnterPictureInPicture = uiCallbacks.onEnterPictureInPicture,
        onClose = uiCallbacks.onClose,
        onZoomIn = zoomHandlers.onZoomIn,
        onZoomOut = zoomHandlers.onZoomOut,
        onResetZoom = zoomHandlers.onResetZoom,
    )
}

private fun Modifier.screenShareSmartZoomPinchModifier(
    fit: ScreenMirrorFit,
    aspect: Float,
    smartZoomDecision: ScreenShareSmartZoomDecision,
    onSmartZoomManualOverride: () -> Unit,
    onSmartZoomDecision: (ScreenShareSmartZoomDecision) -> Unit,
    onLastInteraction: () -> Unit,
): Modifier = pointerInput(fit, aspect, smartZoomDecision) {
    awaitPointerEventScope {
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            onLastInteraction()
            val activePointers = event.changes.filter { it.pressed }
            if (activePointers.size >= 2) {
                val p1 = activePointers[0]
                val p2 = activePointers[1]
                val currentDist = (p1.position - p2.position).getDistance()
                val prevDist = (p1.previousPosition - p2.previousPosition).getDistance()
                if (prevDist > 0f && currentDist > 0f) {
                    val scaleMultiplier = currentDist / prevDist
                    val currentCentroid = (p1.position + p2.position) / 2f
                    val prevCentroid = (p1.previousPosition + p2.previousPosition) / 2f
                    val panDelta = currentCentroid - prevCentroid
                    onSmartZoomManualOverride()
                    val currentScale = smartZoomDecision.scale
                    val currentTranslation = smartZoomDecision.translation
                    val newScale = (currentScale * scaleMultiplier).coerceIn(1f, 5f)
                    val halfW = size.width / 2f
                    val halfH = size.height / 2f
                    val centroidX = currentCentroid.x - halfW
                    val centroidY = currentCentroid.y - halfH
                    var newTranslationX = (currentTranslation.x - centroidX) * scaleMultiplier + centroidX + panDelta.x
                    var newTranslationY = (currentTranslation.y - centroidY) * scaleMultiplier + centroidY + panDelta.y
                    val maxTransX = halfW * (newScale - 1f)
                    val maxTransY = halfH * (newScale - 1f)
                    newTranslationX = newTranslationX.coerceIn(-maxTransX, maxTransX)
                    newTranslationY = newTranslationY.coerceIn(-maxTransY, maxTransY)
                    onSmartZoomDecision(
                        ScreenShareSmartZoomDecision(
                            scale = newScale,
                            translation = Offset(newTranslationX, newTranslationY),
                            isAutoFollowing = false,
                        ),
                    )
                }
                event.changes.forEach { it.consume() }
            }
        }
    }
}
