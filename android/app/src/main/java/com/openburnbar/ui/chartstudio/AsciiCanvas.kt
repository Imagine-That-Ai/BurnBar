package com.openburnbar.ui.chartstudio

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Renders an [AsciiSpec] inside a mock terminal — three traffic-light dots,
 * a small tab strip labeled with the spec variant, then the monospaced body.
 * Matches the iOS `AsciiCanvasView` chrome.
 */
@Composable
fun AsciiCanvas(
    spec: AsciiSpec,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF0E0C18))
            .border(
                width = 0.75.dp,
                color = AuroraColors.lightBorder.copy(alpha = 0.18f),
                shape = RoundedCornerShape(12.dp)
            )
    ) {
        TerminalChrome(variant = spec.variant, title = spec.title)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 120.dp, max = 280.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Text(
                text = spec.body,
                style = TextStyle(
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    color = Color(0xFFD4E4FF),
                    fontWeight = FontWeight.Normal,
                    lineHeight = 15.sp
                )
            )
        }
    }
}

@Composable
private fun TerminalChrome(variant: String, title: String?) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF151229))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFFFF5F57)))
        Spacer(Modifier.width(4.dp))
        Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFFFEBC2E)))
        Spacer(Modifier.width(4.dp))
        Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF28C840)))
        Spacer(Modifier.width(AuroraSpacing.md.dp))
        Text(
            text = title ?: variantLabel(variant),
            style = AuroraType.tiny.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun variantLabel(variant: String): String = when (variant) {
    "bar"       -> "ascii — bar"
    "sparkline" -> "ascii — sparkline"
    "heatmap"   -> "ascii — heatmap"
    "banner"    -> "ascii — banner"
    else        -> "ascii — scene"
}
