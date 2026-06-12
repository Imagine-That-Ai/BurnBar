// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.runtime.Composable

@Composable
fun PulseHeroBurnCard(metrics: PulseHeroCardMetrics) {
    PulseHeroBurnCardBody(metrics = metrics)
}
