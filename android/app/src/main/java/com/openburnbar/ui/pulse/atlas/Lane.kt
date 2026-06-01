@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.ui.graphics.Color
import com.openburnbar.data.derived.TrendDataDigest

internal data class Lane(
    val model: TrendDataDigest.ModelSlice,
    val color: Color,
    val velocity: Double,
    val sparklineValues: List<Float>,
)
