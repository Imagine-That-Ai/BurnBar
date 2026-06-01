@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.ui.theme.LocalUIMode
import com.openburnbar.ui.theme.UIMode

enum class CookingLoaderStyle {
    /** Inline spinner (~24dp). Use for buttons, header refreshes, status rows. */
    INLINE,

    /** Page-level loader (~60dp). Use for full-screen loading or panel states. */
    PANEL,

    /** Hero loader (~100dp). Use for prominent first-run or onboarding moments. */
    HERO,
}

/**
 * A playful, dancing eggs-and-bacon skillet loading indicator that replaces the standard
 * circular spinner in Cooking mode. The skillet bounces and sways reactively to a gentle rhythm.
 */
@Composable
fun CookingLoader(style: CookingLoaderStyle = CookingLoaderStyle.PANEL, label: String? = null, tint: Color? = null, modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current

    val size: Dp =
        when (style) {
            CookingLoaderStyle.INLINE -> 24.dp
            CookingLoaderStyle.PANEL -> 60.dp
            CookingLoaderStyle.HERO -> 100.dp
        }

    val labelTextSize =
        when (style) {
            CookingLoaderStyle.INLINE -> 11.sp
            CookingLoaderStyle.PANEL -> 13.sp
            CookingLoaderStyle.HERO -> 16.sp
        }

    val labelFontWeight =
        when (style) {
            CookingLoaderStyle.INLINE, CookingLoaderStyle.PANEL -> FontWeight.Medium
            CookingLoaderStyle.HERO -> FontWeight.SemiBold
        }

    val spacing: Dp =
        when (style) {
            CookingLoaderStyle.INLINE -> 4.dp
            CookingLoaderStyle.PANEL -> 10.dp
            CookingLoaderStyle.HERO -> 14.dp
        }

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(spacing),
    ) {
        CookingLoaderSkillet(size = size, label = label, reduceMotion = reduceMotion)

        if (!label.isNullOrEmpty()) {
            Text(
                text = label,
                fontSize = labelTextSize,
                fontWeight = labelFontWeight,
                color = tint ?: MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }
    }
}

/**
 * A mode-aware loading wrapper that inspects the ambient UIMode. Displays the playful
 * dancing CookingLoader when in Cooking mode, falling back to a CircularProgressIndicator.
 */
@Composable
fun ModeAwareLoader(
    modifier: Modifier = Modifier,
    style: CookingLoaderStyle = CookingLoaderStyle.PANEL,
    label: String? = null,
    tint: Color? = null,
    strokeWidth: Dp = 3.dp,
) {
    val uiMode = LocalUIMode.current

    if (uiMode == UIMode.COOKING) {
        CookingLoader(
            style = style,
            label = label,
            tint = tint,
            modifier = modifier,
        )
    } else {
        Column(
            modifier = modifier,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(
                color = tint ?: MaterialTheme.colorScheme.primary,
                strokeWidth = strokeWidth,
                modifier =
                Modifier.size(
                    when (style) {
                        CookingLoaderStyle.INLINE -> 20.dp
                        CookingLoaderStyle.PANEL -> 36.dp
                        CookingLoaderStyle.HERO -> 56.dp
                    },
                ),
            )
            if (!label.isNullOrEmpty() && style != CookingLoaderStyle.INLINE) {
                Text(
                    text = label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = tint ?: MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
