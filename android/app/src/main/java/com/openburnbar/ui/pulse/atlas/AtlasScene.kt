package com.openburnbar.ui.pulse.atlas

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.StackedLineChart
import androidx.compose.material.icons.filled.Storage
import androidx.compose.ui.graphics.vector.ImageVector

/** The three rendered scenes in the Trend Atlas card. */
enum class AtlasScene(val label: String, val subtitle: String, val icon: ImageVector) {
    SPEND("Spend", "Daily spend · stacked by provider", Icons.Filled.StackedLineChart),
    MODELS("Models", "Top models · share, velocity, rank", Icons.Filled.Speed),
    CACHE("Cache", "Sessions · duration vs cache hit rate", Icons.Filled.Storage),
}
