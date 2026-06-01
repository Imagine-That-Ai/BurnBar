@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.derived.TrendDataDigest

@Composable
internal fun SpendStreamChartArea(
    daily: List<TrendDataDigest.DailySeries>,
    selectedIndex: Int?,
    onSelect: (Int?) -> Unit,
) {
    Box(modifier = Modifier.fillMaxWidth().height(180.dp)) {
        StreamGraphCanvas(
            series = daily,
            sweepProgress = 1f,
            selectedIndex = selectedIndex,
            onSelect = onSelect,
        )
        TotalRibbon(
            modifier = Modifier.fillMaxWidth().height(16.dp).padding(horizontal = 4.dp).padding(top = 4.dp),
        )
        selectedIndex?.let { index ->
            SelectedAnnotation(
                daily[index],
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 4.dp),
            )
        }
    }
}

@Composable
internal fun SpendStreamDateRangeRow(daily: List<TrendDataDigest.DailySeries>) {
    Spacer(Modifier.height(8.dp))
    androidx.compose.foundation.layout.Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.SpaceBetween,
    ) {
        androidx.compose.material3.Text(
            text = formatDayShort(daily.first().date),
            style = com.openburnbar.ui.theme.AuroraType.tiny,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
        androidx.compose.material3.Text(
            text = formatDayShort(daily.last().date),
            style = com.openburnbar.ui.theme.AuroraType.tiny,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun SpendStreamScene(digest: TrendDataDigest, modifier: Modifier = Modifier) {
    val daily = digest.daily
    if (daily.isEmpty() || daily.all { it.total <= 0.0 }) {
        EmptySpendScene(modifier)
        return
    }
    var selectedIndex by remember(daily.size) { mutableStateOf<Int?>(null) }
    Column(modifier = modifier) {
        SpendStreamChartArea(daily = daily, selectedIndex = selectedIndex, onSelect = { selectedIndex = it })
        SpendStreamDateRangeRow(daily = daily)
        Spacer(Modifier.height(12.dp))
        HourOfDayHeatStrip(digest = digest)
        Spacer(Modifier.height(8.dp))
        ProviderLegend(daily)
    }
}
