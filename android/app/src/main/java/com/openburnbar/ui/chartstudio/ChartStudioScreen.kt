package com.openburnbar.ui.chartstudio

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.chartstudio.charts.NativeChart
import com.openburnbar.ui.chartstudio.charts.NativeChartDisplay
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.pulse.SectionHeaderRow
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Top-level Chart Studio surface — fullscreen-only, hosted by the nav scaffold
 * inside an `AnimatedVisibility` that slides from the bottom. Owns:
 *
 *  • the prompt composer
 *  • streaming Hermes responses → decoded rendering
 *  • the quick-facts strip + gallery + suggested prompts + recent canvases
 *  • the AI canvas section (visible only when there's a rendering / streaming
 *    / error state)
 *
 * Closing dismisses the presenter; minimizing hands off to the FAB while
 * keeping the digest snapshot alive.
 */
@Composable
fun ChartStudioScreen(
    digest: TrendDataDigest,
    hermes: HermesService,
    onClose: () -> Unit,
    onMinimize: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val state = rememberChartStudioState()
    val connection by hermes.selectedConnection.collectAsState()
    val canvases by ChartStudioCanvasStore.canvases.collectAsState()

    LaunchedEffect(context) { ChartStudioCanvasStore.bind(context) }

    val bridge = remember(connection) { ChartStudioHermesBridge(connection = connection) }
    val scope = rememberCoroutineScope()

    fun submit(prompt: String) {
        val trimmed = prompt.trim()
        if (trimmed.isEmpty() || state.isStreaming) return
        HapticBus.light(context)
        state.reset()
        state.lastSubmittedPrompt = trimmed
        state.prompt = ""
        state.isStreaming = true
        state.streamJob?.cancel()
        state.streamJob = scope.launch {
            val systemPrompt = ChartStudioPromptEngine.systemPrompt(digest)
            bridge.stream(systemPrompt = systemPrompt, userPrompt = trimmed).collectLatest { event ->
                when (event) {
                    is ChartStudioHermesBridge.Event.Partial -> {
                        state.streamingText = event.text
                    }
                    is ChartStudioHermesBridge.Event.Completed -> {
                        state.streamingText = event.text
                        val rendering = ChartSpecRenderer.decode(event.text)
                        state.rendering = rendering
                        state.isStreaming = false
                        // Persist successful renderings only (errors stay ephemeral).
                        if (rendering !is ChartStudioRendering.Error) {
                            ChartStudioCanvasStore.add(context, trimmed, event.text)
                            HapticBus.success(context)
                        } else {
                            state.error = (rendering as ChartStudioRendering.Error).message
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
        }
    }

    Box(modifier = modifier.fillMaxSize().background(AuroraColors.darkBackground)) {
        AuroraBackdrop()

        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            HeaderBar(
                connection = connection,
                isStreaming = state.isStreaming,
                onMinimize = onMinimize,
                onClose = onClose
            )

            // Body scrolls; composer bar pinned at the bottom.
            Box(modifier = Modifier.weight(1f)) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = AuroraSpacing.lg.dp)
                        .padding(top = AuroraSpacing.md.dp, bottom = 88.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
                ) {
                    QuickFactStrip(digest)
                    InsightsGallery(digest)
                    PromptCarousel(
                        suggestions = ChartStudioPromptEngine.suggestedPrompts(digest),
                        onSelect = { suggestion -> submit(suggestion) }
                    )
                    RecentCanvasesStrip(
                        canvases = canvases,
                        onReplay = { canvas ->
                            state.rendering = ChartSpecRenderer.decode(canvas.rawJson)
                            state.error = null
                            state.isStreaming = false
                        }
                    )

                    if (state.hasAIRendering) {
                        AICanvasSection(
                            state = state,
                            onClear = { state.reset() },
                            onRetry = {
                                state.lastSubmittedPrompt?.let { submit(it) }
                            },
                            onFollowUp = { followUp -> submit(followUp) }
                        )
                    } else {
                        WelcomeBlock()
                    }
                }
            }

            ComposerBar(
                state = state,
                onSubmit = ::submit,
                onStop = {
                    state.streamJob?.cancel()
                    state.isStreaming = false
                }
            )
        }
    }
}

// ── Header ─────────────────────────────────────────────────────────────────

@Composable
private fun HeaderBar(
    connection: com.openburnbar.data.hermes.HermesConnectionRecord,
    isStreaming: Boolean,
    onMinimize: () -> Unit,
    onClose: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(AuroraColors.hermesAureate.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(18.dp)
            )
        }
        Spacer(Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Chart Studio",
                style = AuroraType.title,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = subtitleFor(connection, isStreaming),
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        IconButton(onClick = onMinimize) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = "Minimize",
                tint = AuroraColors.hermesAureate
            )
        }
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close",
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun subtitleFor(
    connection: com.openburnbar.data.hermes.HermesConnectionRecord,
    isStreaming: Boolean
): String = when {
    isStreaming -> "Drawing with ${connection.id}…"
    connection.endpointURL.isNullOrBlank() -> "Hermes offline — connect from Settings"
    else -> "${connection.id} · ask for any chart"
}

// ── Quick facts strip ───────────────────────────────────────────────────────

@Composable
private fun QuickFactStrip(digest: TrendDataDigest) {
    val facts = remember(digest) { StandardGallery.quickFacts(digest) }
    if (facts.isEmpty()) return
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        items(facts.size) { i ->
            QuickFactPill(facts[i])
        }
    }
}

@Composable
private fun QuickFactPill(fact: StandardGallery.QuickFact) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = androidx.compose.foundation.BorderStroke(
            0.5.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
        ),
        modifier = Modifier.width(188.dp).height(78.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Text(
                text = fact.label.uppercase(),
                fontSize = 9.sp,
                letterSpacing = 1.4.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = fact.value,
                style = AuroraType.title,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (fact.sparkline.size >= 2) {
                    Box(modifier = Modifier.width(48.dp).height(14.dp)) {
                        AuroraSparkline(
                            data = fact.sparkline,
                            strokeColor = AuroraColors.ember,
                            fillColor = AuroraColors.ember.copy(alpha = 0.18f),
                            strokeWidth = 1.4f
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    text = fact.detail,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

// ── Insights gallery ────────────────────────────────────────────────────────

@Composable
private fun InsightsGallery(digest: TrendDataDigest) {
    val items = remember(digest) { StandardGallery.galleryItems(digest) }
    if (items.isEmpty()) return
    Column {
        SectionHeaderRow(label = "Insights")
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            items.forEach { item ->
                GalleryItemCard(item)
            }
        }
    }
}

@Composable
private fun GalleryItemCard(item: StandardGallery.GalleryItem) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = item.title,
            style = AuroraType.headline,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = item.subtitle,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        when (val r = item.rendering) {
            is ChartStudioRendering.Native -> NativeChart(spec = r.spec, display = NativeChartDisplay.GALLERY)
            is ChartStudioRendering.Mermaid -> Box(modifier = Modifier.fillMaxWidth().height(180.dp)) {
                MermaidCanvas(spec = r.spec)
            }
            is ChartStudioRendering.Ascii -> AsciiCanvas(spec = r.spec)
            is ChartStudioRendering.Insight -> InsightCard(spec = r.spec)
            is ChartStudioRendering.Composed -> Column(
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                r.items.forEach { child -> RenderingHost(child) }
            }
            is ChartStudioRendering.Error -> Text(
                text = r.message,
                style = AuroraType.body,
                color = AuroraColors.warning
            )
        }
    }
}

// ── Prompt carousel ─────────────────────────────────────────────────────────

@Composable
private fun PromptCarousel(suggestions: List<String>, onSelect: (String) -> Unit) {
    if (suggestions.isEmpty()) return
    Column {
        SectionHeaderRow(label = "Ask Hermes")
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(suggestions.size) { i ->
                PromptChip(suggestion = suggestions[i], onSelect = onSelect)
            }
        }
    }
}

@Composable
private fun PromptChip(suggestion: String, onSelect: (String) -> Unit) {
    Surface(
        onClick = { onSelect(suggestion) },
        shape = CircleShape,
        color = AuroraColors.hermesAureate.copy(alpha = 0.12f),
        border = androidx.compose.foundation.BorderStroke(
            0.5.dp,
            AuroraColors.hermesAureate.copy(alpha = 0.45f)
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(11.dp)
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = suggestion,
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.hermesAureate
            )
        }
    }
}

// ── Recent canvases strip ───────────────────────────────────────────────────

@Composable
private fun RecentCanvasesStrip(
    canvases: List<ChartStudioCanvasStore.Canvas>,
    onReplay: (ChartStudioCanvasStore.Canvas) -> Unit
) {
    if (canvases.isEmpty()) return
    Column {
        SectionHeaderRow(label = "Recent")
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(canvases.size) { i ->
                RecentCanvasCard(canvas = canvases[i], onClick = { onReplay(canvases[i]) })
            }
        }
    }
}

@Composable
private fun RecentCanvasCard(canvas: ChartStudioCanvasStore.Canvas, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = androidx.compose.foundation.BorderStroke(
            0.5.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
        ),
        modifier = Modifier.width(200.dp).height(86.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Text(
                text = canvas.title,
                style = AuroraType.caption,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = "Tap to replay",
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ── AI canvas ──────────────────────────────────────────────────────────────

@Composable
private fun AICanvasSection(
    state: ChartStudioState,
    onClear: () -> Unit,
    onRetry: () -> Unit,
    onFollowUp: (String) -> Unit
) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Outlined.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(14.dp)
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = "HERMES ANSWER",
                fontSize = 11.sp,
                letterSpacing = 1.6.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = onClear, contentPadding = PaddingValues(horizontal = 8.dp)) {
                Text("Clear", style = AuroraType.caption, color = AuroraColors.ember)
            }
        }
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
            when {
                state.error != null -> {
                    Text(
                        text = state.error!!,
                        style = AuroraType.body,
                        color = AuroraColors.warning
                    )
                    Spacer(Modifier.height(AuroraSpacing.sm.dp))
                    TextButton(onClick = onRetry) {
                        Text("Try again", color = AuroraColors.ember, fontWeight = FontWeight.SemiBold)
                    }
                }
                state.isStreaming -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Filled.Bolt,
                            contentDescription = null,
                            tint = AuroraColors.amber,
                            modifier = Modifier.size(14.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "Hermes is drawing your chart…",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (state.streamingText.isNotBlank()) {
                        Spacer(Modifier.height(AuroraSpacing.sm.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 80.dp, max = 200.dp)
                                .verticalScroll(rememberScrollState())
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
                                .padding(10.dp)
                        ) {
                            Text(
                                text = state.streamingText,
                                style = TextStyle(
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 10.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            )
                        }
                    }
                }
                state.rendering != null -> {
                    RenderingHost(state.rendering!!, onFollowUp = onFollowUp)
                }
            }
        }
    }
}

@Composable
private fun RenderingHost(
    rendering: ChartStudioRendering,
    onFollowUp: ((String) -> Unit)? = null
) {
    when (rendering) {
        is ChartStudioRendering.Native -> NativeChart(spec = rendering.spec)
        is ChartStudioRendering.Mermaid -> Box(modifier = Modifier.fillMaxWidth().height(260.dp)) {
            MermaidCanvas(spec = rendering.spec)
        }
        is ChartStudioRendering.Ascii -> AsciiCanvas(spec = rendering.spec)
        is ChartStudioRendering.Insight -> InsightCard(
            spec = rendering.spec,
            onFollowUp = onFollowUp
        )
        is ChartStudioRendering.Composed -> Column(
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            rendering.items.forEach { child -> RenderingHost(child, onFollowUp) }
        }
        is ChartStudioRendering.Error -> Text(
            text = rendering.message,
            style = AuroraType.body,
            color = AuroraColors.warning
        )
    }
}

// ── Welcome ────────────────────────────────────────────────────────────────

@Composable
private fun WelcomeBlock() {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Ask for any chart you want",
                    style = AuroraType.title,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "Type in plain English. Hermes will draw it.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Spacer(Modifier.height(AuroraSpacing.md.dp))
        listOf(
            "“Stack my burn last 14 days by provider”",
            "“Heatmap of my hourly usage”",
            "“Where is my cache helping the most?”",
            "“Mermaid diagram of my agent flow”"
        ).forEach { example ->
            Row(modifier = Modifier.padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(4.dp)
                        .clip(CircleShape)
                        .background(AuroraColors.ember)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = example,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

// ── Composer bar ───────────────────────────────────────────────────────────

@Composable
private fun ComposerBar(
    state: ChartStudioState,
    onSubmit: (String) -> Unit,
    onStop: () -> Unit
) {
    var focused by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(
                    colors = listOf(Color.Transparent, AuroraColors.darkBackground.copy(alpha = 0.85f))
                )
            )
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.sm.dp, bottom = AuroraSpacing.md.dp)
            .imePadding()
            .navigationBarsPadding()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.75f))
                .border(
                    width = if (focused) 1.dp else 0.5.dp,
                    color = if (focused) AuroraColors.hermesAureate.copy(alpha = 0.7f)
                            else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    shape = RoundedCornerShape(20.dp)
                )
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(modifier = Modifier.weight(1f)) {
                if (state.prompt.isEmpty()) {
                    Text(
                        text = "Ask Hermes to draw…",
                        style = AuroraType.body,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                BasicTextField(
                    value = state.prompt,
                    onValueChange = { state.prompt = it },
                    textStyle = AuroraType.body.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(AuroraColors.ember),
                    modifier = Modifier
                        .fillMaxWidth()
                        .onFocusChanged { focused = it.isFocused }
                )
            }
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = {
                    if (state.isStreaming) onStop() else onSubmit(state.prompt)
                },
                enabled = state.isStreaming || state.prompt.isNotBlank()
            ) {
                Icon(
                    imageVector = if (state.isStreaming) Icons.Filled.Stop
                                  else Icons.AutoMirrored.Filled.Send,
                    contentDescription = if (state.isStreaming) "Stop" else "Send",
                    tint = if (state.isStreaming) AuroraColors.warning else AuroraColors.ember
                )
            }
        }
    }
}

// ── Animated overlay wrapper (called from BurnBarNavHost) ─────────────────

@Composable
fun ChartStudioOverlay(
    hermes: HermesService,
    modifier: Modifier = Modifier
) {
    val mode by rememberChartStudioMode()
    val snapshot by rememberChartStudioSnapshot()
    rememberChartStudioFabBinding()

    AnimatedVisibility(
        visible = mode == ChartStudioPresenter.Mode.Fullscreen && snapshot != null,
        enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
        exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
        modifier = modifier.fillMaxSize()
    ) {
        snapshot?.let { snap ->
            ChartStudioScreen(
                digest = snap.digest,
                hermes = hermes,
                onClose = { ChartStudioPresenter.dismiss() },
                onMinimize = { ChartStudioPresenter.minimize() }
            )
        }
    }

    AnimatedVisibility(
        visible = mode == ChartStudioPresenter.Mode.Minimized,
        enter = fadeIn() + slideInVertically(initialOffsetY = { it / 2 }),
        exit = fadeOut() + slideOutVertically(targetOffsetY = { it / 2 }),
        modifier = modifier.fillMaxSize()
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = 96.dp, end = 16.dp),
            contentAlignment = Alignment.BottomEnd
        ) {
            ChartStudioFab()
        }
    }
}
