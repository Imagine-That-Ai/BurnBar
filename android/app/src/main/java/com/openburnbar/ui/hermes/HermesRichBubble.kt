package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

sealed class RichRun {
    data class Body(val text: String) : RichRun()
    data class Atom(val label: String, val url: String) : RichRun()
    data class Bold(val text: String) : RichRun()
    data class Code(val text: String) : RichRun()
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun HermesRichBubble(
    text: String,
    onAtomClick: (String, String) -> Unit,
    modifier: Modifier = Modifier
) {
    val runs = rememberRichRuns(text)

    androidx.compose.foundation.layout.FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        runs.forEach { run ->
            when (run) {
                is RichRun.Body -> {
                    Text(
                        text = run.text,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        lineHeight = 21.sp
                    )
                }
                is RichRun.Atom -> {
                    HermesAtomChip(
                        label = run.label,
                        url = run.url,
                        onClick = onAtomClick
                    )
                }
                is RichRun.Bold -> {
                    Text(
                        text = run.text,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        lineHeight = 21.sp
                    )
                }
                is RichRun.Code -> {
                    Text(
                        text = run.text,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .clip(RoundedCornerShape(5.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.85f))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                        lineHeight = 21.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun rememberRichRuns(text: String): List<RichRun> {
    return androidx.compose.runtime.remember(text) {
        parseRichText(text)
    }
}

fun parseRichText(text: String): List<RichRun> {
    val runs = mutableListOf<RichRun>()
    var remaining = text

    // Combined regex for atoms, bold, and code
    val regex = Regex("(\\*\\*([^*]+)\\*\\*)|(\\`([^`]+)\\`)|(\\[([^\\]]+)\\]\\(([^)]+)\\))")

    while (remaining.isNotEmpty()) {
        val match = regex.find(remaining)
        if (match == null) {
            if (remaining.isNotBlank()) {
                runs.add(RichRun.Body(remaining))
            }
            break
        }

        val before = remaining.substring(0, match.range.first)
        if (before.isNotBlank()) {
            runs.add(RichRun.Body(before))
        }

        when {
            match.groupValues[1].isNotEmpty() -> {
                // Bold
                runs.add(RichRun.Bold(match.groupValues[2]))
            }
            match.groupValues[3].isNotEmpty() -> {
                // Code
                runs.add(RichRun.Code(match.groupValues[4]))
            }
            match.groupValues[5].isNotEmpty() -> {
                // Atom link
                runs.add(RichRun.Atom(match.groupValues[6], match.groupValues[7]))
            }
        }

        remaining = remaining.substring(match.range.last + 1)
    }

    return runs
}
