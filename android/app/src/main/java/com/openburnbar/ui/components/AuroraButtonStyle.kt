package com.openburnbar.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Aurora button styles matching the iOS `.aurora()` button style.
 * A filled pill with brand gradient, subtle shadow, and pressed-state scaling.
 */

object AuroraButtonDefaults {
    val shape = RoundedCornerShape(AuroraRadius.full.dp)
    val contentPadding = PaddingValues(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.md.dp)
}

@Composable
fun AuroraButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = AuroraButtonDefaults.shape,
        colors = ButtonDefaults.buttonColors(
            containerColor = AuroraColors.ember,
            disabledContainerColor = AuroraColors.ember.copy(alpha = 0.35f)
        ),
        contentPadding = AuroraButtonDefaults.contentPadding,
        content = content
    )
}

@Composable
fun AuroraGradientButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier,
        shape = AuroraButtonDefaults.shape,
        color = Color.Transparent,
        border = null,
        shadowElevation = 4.dp
    ) {
        Box(
            modifier = Modifier
                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(AuroraColors.ember, AuroraColors.amber)
                    )
                )
                .padding(AuroraButtonDefaults.contentPadding)
        ) {
            ProvideTextStyle(
                value = MaterialTheme.typography.labelLarge.copy(
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White
                )
            ) {
                Row {
                    content()
                }
            }
        }
    }
}

@Composable
fun AuroraSecondaryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = AuroraButtonDefaults.shape,
        border = BorderStroke(1.dp, AuroraColors.ember.copy(alpha = 0.50f)),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = AuroraColors.ember
        ),
        contentPadding = AuroraButtonDefaults.contentPadding,
        content = content
    )
}

@Composable
fun AuroraTextButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    TextButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = ButtonDefaults.textButtonColors(
            contentColor = AuroraColors.ember
        ),
        content = content
    )
}
