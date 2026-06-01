@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.ui.chartstudio.charts.NativeChartDisplay
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.pulse.SectionHeaderRow
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography
// ── Header ─────────────────────────────────────────────────────────────────

@Composable
internal fun ChartStudioScrollBody(
    digest: TrendDataDigest,
    state: ChartStudioState,
    canvases: List<ChartStudioCanvasStore.Canvas>,
    onSubmit: (String) -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = 88.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        QuickFactStrip(digest)
        InsightsGallery(digest)
        PromptCarousel(
            suggestions = ChartStudioPromptEngine.suggestedPrompts(digest),
            onSelect = onSubmit,
        )
        RecentCanvasesStrip(
            canvases = canvases,
            onReplay = { canvas -> replayChartStudioCanvas(state, canvas) },
        )
        if (state.hasAIRendering) {
            AICanvasSection(
                state = state,
                onClear = { state.reset() },
                onRetry = { state.lastSubmittedPrompt?.let(onSubmit) },
                onFollowUp = onSubmit,
            )
        } else {
            WelcomeBlock()
        }
    }
}

@Composable
internal fun HeaderBar(connection: com.openburnbar.data.hermes.HermesConnectionRecord, isStreaming: Boolean, onMinimize: () -> Unit, onClose: () -> Unit) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier =
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(AuroraColors.hermesAureate.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Chart Studio",
                style = AuroraType.title,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitleFor(connection, isStreaming),
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onMinimize) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = "Minimize",
                tint = AuroraColors.hermesAureate,
            )
        }
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// ── AI canvas ──────────────────────────────────────────────────────────────

@Composable
internal fun AICanvasSection(state: ChartStudioState, onClear: () -> Unit, onRetry: () -> Unit, onFollowUp: (String) -> Unit) {
    Column {
        AICanvasSectionHeader(onClear = onClear)
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
            AICanvasSectionBody(state = state, onRetry = onRetry, onFollowUp = onFollowUp)
        }
    }
}

@Composable
private fun AICanvasSectionHeader(onClear: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Outlined.AutoAwesome,
            contentDescription = null,
            tint = AuroraColors.hermesAureate,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = "HERMES ANSWER",
            fontSize = 11.sp,
            letterSpacing = 1.6.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onClear, contentPadding = PaddingValues(horizontal = 8.dp)) {
            Text("Clear", style = AuroraType.caption, color = AuroraColors.ember)
        }
    }
}

@Composable
private fun AICanvasSectionBody(state: ChartStudioState, onRetry: () -> Unit, onFollowUp: (String) -> Unit) {
    when {
        state.error != null -> AICanvasErrorBody(errorMessage = state.error ?: return, onRetry = onRetry)
        state.isStreaming -> AICanvasStreamingBody(streamingText = state.streamingText)
        state.rendering != null -> {
            val rendering = state.rendering ?: return
            RenderingHost(rendering, onFollowUp = onFollowUp)
        }
    }
}

@Composable
private fun AICanvasErrorBody(errorMessage: String, onRetry: () -> Unit) {
    Text(text = errorMessage, style = AuroraType.body, color = AuroraColors.warning)
    Spacer(Modifier.height(AuroraSpacing.sm.dp))
    TextButton(onClick = onRetry) {
        Text("Try again", color = AuroraColors.ember, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun AICanvasStreamingBody(streamingText: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.Bolt,
            contentDescription = null,
            tint = AuroraColors.amber,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = "Hermes is drawing your chart…",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    if (streamingText.isNotBlank()) {
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 80.dp, max = 200.dp)
                .verticalScroll(rememberScrollState())
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
                .padding(10.dp),
        ) {
            Text(
                text = streamingText,
                style =
                TextStyle(
                    fontFamily = FontFamily.Monospace,
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            )
        }
    }
}

@Composable
internal fun QuickFactStrip(digest: TrendDataDigest) {
    val facts = remember(digest) { StandardGallery.quickFacts(digest) }
    if (facts.isEmpty()) return
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(facts.size) { i ->
            QuickFactPill(facts[i])
        }
    }
}

@Composable
internal fun QuickFactPill(fact: StandardGallery.QuickFact) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border =
        androidx.compose.foundation.BorderStroke(
            0.5.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
        ),
        modifier = Modifier.width(188.dp).height(78.dp),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Text(
                text = fact.label.uppercase(),
                fontSize = 9.sp,
                letterSpacing = 1.4.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = fact.value,
                style = AuroraType.title,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (fact.sparkline.size >= 2) {
                    Box(modifier = Modifier.width(48.dp).height(14.dp)) {
                        AuroraSparkline(
                            data = fact.sparkline,
                            strokeColor = AuroraColors.ember,
                            fillColor = AuroraColors.ember.copy(alpha = 0.18f),
                            strokeWidth = 1.4f,
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    text = fact.detail,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ── Insights gallery ────────────────────────────────────────────────────────

@Composable
internal fun InsightsGallery(digest: TrendDataDigest) {
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
internal fun GalleryItemCard(item: StandardGallery.GalleryItem) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = item.title,
            style = AuroraType.headline,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = item.subtitle,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        when (val r = item.rendering) {
            is ChartStudioRendering.Native -> NativeChart(spec = r.spec, display = NativeChartDisplay.GALLERY)
            is ChartStudioRendering.Mermaid ->
                Box(modifier = Modifier.fillMaxWidth().height(180.dp)) {
                    MermaidCanvas(spec = r.spec)
                }
            is ChartStudioRendering.Ascii -> AsciiCanvas(spec = r.spec)
            is ChartStudioRendering.Insight -> InsightCard(spec = r.spec)
            is ChartStudioRendering.Composed ->
                Column(
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                ) {
                    r.items.forEach { child -> RenderingHost(child) }
                }
            is ChartStudioRendering.Error ->
                Text(
                    text = r.message,
                    style = AuroraType.body,
                    color = AuroraColors.warning,
                )
        }
    }
}

// ── Prompt carousel ─────────────────────────────────────────────────────────

@Composable
internal fun PromptCarousel(suggestions: List<String>, onSelect: (String) -> Unit) {
    if (suggestions.isEmpty()) return
    Column {
        SectionHeaderRow(label = "Ask Hermes")
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(suggestions.size) { i ->
                PromptChip(suggestion = suggestions[i], onSelect = onSelect)
            }
        }
    }
}

@Composable
internal fun PromptChip(suggestion: String, onSelect: (String) -> Unit) {
    Surface(
        onClick = { onSelect(suggestion) },
        shape = CircleShape,
        color = AuroraColors.hermesAureate.copy(alpha = 0.12f),
        border =
        androidx.compose.foundation.BorderStroke(
            0.5.dp,
            AuroraColors.hermesAureate.copy(alpha = 0.45f),
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(11.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = suggestion,
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.hermesAureate,
            )
        }
    }
}

// ── Recent canvases strip ───────────────────────────────────────────────────

@Composable
internal fun RecentCanvasesStrip(canvases: List<ChartStudioCanvasStore.Canvas>, onReplay: (ChartStudioCanvasStore.Canvas) -> Unit) {
    if (canvases.isEmpty()) return
    Column {
        SectionHeaderRow(label = "Recent")
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(canvases.size) { i ->
                RecentCanvasCard(canvas = canvases[i], onClick = { onReplay(canvases[i]) })
            }
        }
    }
}

@Composable
internal fun RecentCanvasCard(canvas: ChartStudioCanvasStore.Canvas, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border =
        androidx.compose.foundation.BorderStroke(
            0.5.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
        ),
        modifier = Modifier.width(200.dp).height(86.dp),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Text(
                text = canvas.title,
                style = AuroraType.caption,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = "Tap to replay",
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun RenderingHost(rendering: ChartStudioRendering, onFollowUp: ((String) -> Unit)? = null) {
    when (rendering) {
        is ChartStudioRendering.Native -> NativeChart(spec = rendering.spec)
        is ChartStudioRendering.Mermaid ->
            Box(modifier = Modifier.fillMaxWidth().height(260.dp)) {
                MermaidCanvas(spec = rendering.spec)
            }
        is ChartStudioRendering.Ascii -> AsciiCanvas(spec = rendering.spec)
        is ChartStudioRendering.Insight ->
            InsightCard(
                spec = rendering.spec,
                onFollowUp = onFollowUp,
            )
        is ChartStudioRendering.Composed ->
            Column(
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                rendering.items.forEach { child -> RenderingHost(child, onFollowUp) }
            }
        is ChartStudioRendering.Error ->
            Text(
                text = rendering.message,
                style = AuroraType.body,
                color = AuroraColors.warning,
            )
    }
}

// ── Welcome ────────────────────────────────────────────────────────────────

@Composable
internal fun WelcomeBlock() {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Ask for any chart you want",
                    style = AuroraType.title,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "Type in plain English. Hermes will draw it.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.height(AuroraSpacing.md.dp))
        listOf(
            "“Stack my burn last 14 days by provider”",
            "“Heatmap of my hourly usage”",
            "“Where is my cache helping the most?”",
            "“Mermaid diagram of my agent flow”",
        ).forEach { example ->
            Row(modifier = Modifier.padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier =
                    Modifier
                        .size(4.dp)
                        .clip(CircleShape)
                        .background(AuroraColors.ember),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = example,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

// ── Composer bar ───────────────────────────────────────────────────────────

@Composable
internal fun ComposerBar(state: ChartStudioState, onSubmit: (String) -> Unit, onStop: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    ComposerBarContainer {
        ComposerInputRow(
            state = state,
            focused = focused,
            onSubmit = onSubmit,
            onStop = onStop,
            onFocusChanged = { focused = it },
        )
    }
}

@Composable
private fun ComposerBarContainer(content: @Composable () -> Unit) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(
                    colors = listOf(Color.Transparent, AuroraColors.darkBackground.copy(alpha = 0.85f)),
                ),
            )
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.sm.dp, bottom = AuroraSpacing.md.dp)
            .imePadding()
            .navigationBarsPadding(),
    ) {
        content()
    }
}

@Composable
private fun ComposerInputRow(
    state: ChartStudioState,
    focused: Boolean,
    onSubmit: (String) -> Unit,
    onStop: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.75f))
            .border(
                width = if (focused) 1.dp else 0.5.dp,
                color =
                if (focused) {
                    AuroraColors.hermesAureate.copy(alpha = 0.7f)
                } else {
                    MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
                },
                shape = RoundedCornerShape(20.dp),
            )
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ComposerPromptField(state = state, onFocusChanged = onFocusChanged)
        Spacer(Modifier.width(8.dp))
        ComposerSendButton(state = state, onSubmit = onSubmit, onStop = onStop)
    }
}

@Composable
private fun ComposerPromptField(state: ChartStudioState, onFocusChanged: (Boolean) -> Unit) {
    Box(modifier = Modifier.weight(1f)) {
        if (state.prompt.isEmpty()) {
            Text(
                text = "Ask Hermes to draw…",
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        BasicTextField(
            value = state.prompt,
            onValueChange = { state.prompt = it },
            textStyle = AuroraType.body.copy(color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(AuroraColors.ember),
            modifier =
            Modifier
                .fillMaxWidth()
                .onFocusChanged { onFocusChanged(it.isFocused) },
        )
    }
}

@Composable
private fun ComposerSendButton(state: ChartStudioState, onSubmit: (String) -> Unit, onStop: () -> Unit) {
    IconButton(
        onClick = {
            if (state.isStreaming) onStop() else onSubmit(state.prompt)
        },
        enabled = state.isStreaming || state.prompt.isNotBlank(),
    ) {
        Icon(
            imageVector =
            if (state.isStreaming) {
                Icons.Filled.Stop
            } else {
                Icons.AutoMirrored.Filled.Send
            },
            contentDescription = if (state.isStreaming) "Stop" else "Send",
            tint = if (state.isStreaming) AuroraColors.warning else AuroraColors.ember,
        )
    }
}
