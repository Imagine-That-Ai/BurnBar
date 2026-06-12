package com.openburnbar.ui.hermes

import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesAtom
import com.openburnbar.data.hermes.HermesAtomParser
import com.openburnbar.data.hermes.HermesAtomRun
import com.openburnbar.ui.theme.AuroraColors

// MARK: - HermesRichBubble (Compose)
//
// One assistant message rendered with full atom-aware layout. Mirrors the
// iOS `HermesRichBubble` semantics:
//
//   1. `HermesAtomParser.parse(text)` splits the text into a typed run
//      stream: body / atom / mention / code.
//   2. Runs are concatenated into an `AnnotatedString` using `SpanStyle`s
//      for mentions / code. Atoms are emitted as `inlineContent` placeholder
//      spans that resolve to `HermesAtomChip` composables.
//   3. A single `Text(buildAnnotatedString)` renders the whole bubble so
//      prose flows naturally and chips never break mid-line.
//
@Composable
fun HermesRichBubble(
    text: String,
    modifier: Modifier = Modifier,
    isStreaming: Boolean = false,
    baseSize: Float = 15f,
    baseColor: Color = MaterialTheme.colorScheme.onSurface,
    mentionColor: Color = AuroraColors.hermesAureate,
    codeColor: Color = MaterialTheme.colorScheme.onSurface,
    codeBackground: Color = MaterialTheme.colorScheme.surfaceVariant,
    onAtomTap: ((HermesAtom) -> Unit)? = null,
) {
    val runs = remember(text) { HermesAtomParser.parse(text) }
    val inlineContent =
        remember(text, baseSize, onAtomTap) {
            buildInlineContentMap(runs, baseSize, onAtomTap)
        }
    val annotated =
        remember(text, mentionColor, codeColor, codeBackground, baseColor, isStreaming) {
            buildAnnotated(runs, mentionColor, codeColor, codeBackground, baseColor, isStreaming)
        }
    Text(
        text = annotated,
        color = baseColor,
        fontSize = baseSize.sp,
        lineHeight = (baseSize * 1.36f).sp,
        inlineContent = inlineContent,
        modifier = modifier,
    )
}

/**
 * Legacy URL-driven entry point — kept so call sites that were already
 * passing a `(label, url)` tap callback keep compiling. New code should
 * use the typed atom callback above.
 */
@Composable
fun HermesRichBubble(text: String, onAtomClick: (String, String) -> Unit, modifier: Modifier = Modifier) {
    HermesRichBubble(
        text = text,
        modifier = modifier,
        onAtomTap = { atom ->
            val url = com.openburnbar.data.hermes.HermesAtomURL.encode(atom)
            onAtomClick(atom.fallbackLabel, url)
        },
    )
}

private fun buildAnnotated(
    runs: List<HermesAtomRun>,
    mentionColor: Color,
    codeColor: Color,
    codeBackground: Color,
    baseColor: Color,
    isStreaming: Boolean,
): AnnotatedString = buildAnnotatedString {
    for ((index, run) in runs.withIndex()) {
        when (run) {
            is HermesAtomRun.Text -> {
                withStyle(SpanStyle(color = baseColor)) {
                    append(run.text)
                }
            }
            is HermesAtomRun.Mention -> {
                withStyle(
                    SpanStyle(
                        color = mentionColor,
                        fontWeight = FontWeight.SemiBold,
                    ),
                ) {
                    append(run.handle)
                }
            }
            is HermesAtomRun.Code -> {
                withStyle(
                    SpanStyle(
                        color = codeColor,
                        background = codeBackground,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Medium,
                    ),
                ) {
                    append(run.code)
                }
            }
            is HermesAtomRun.Atom -> {
                appendInlineContent("atom-$index", run.label)
            }
        }
    }
    if (isStreaming) {
        withStyle(SpanStyle(color = mentionColor, fontWeight = FontWeight.SemiBold)) {
            append(" ▍")
        }
    }
}

private fun buildInlineContentMap(runs: List<HermesAtomRun>, baseSize: Float, onAtomTap: ((HermesAtom) -> Unit)?): Map<String, InlineTextContent> {
    val out = mutableMapOf<String, InlineTextContent>()
    for ((index, run) in runs.withIndex()) {
        if (run is HermesAtomRun.Atom) {
            out["atom-$index"] =
                hermesAtomInlineTextContent(
                    atom = run.atom,
                    label = run.label,
                    baseSize = baseSize,
                    onTap = onAtomTap,
                )
        }
    }
    return out
}
