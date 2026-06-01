package com.openburnbar.ui.chartstudio

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Renders an [InsightSpec] as an Aurora glass card.
 */
@Composable
fun InsightCard(spec: InsightSpec, modifier: Modifier = Modifier, onFollowUp: ((String) -> Unit)? = null) {
    InsightCardContent(spec = spec, modifier = modifier, onFollowUp = onFollowUp)
}
