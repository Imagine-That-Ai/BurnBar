package com.openburnbar.ui.insights

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.services.InMemoryInsightDataSource
import com.openburnbar.data.insights.services.adapters.LocalRuleBasedAdapter
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Top-level Insights screen. Shows the canvas library (list of saved canvases)
 * and a default "Today" canvas built by the local rule engine on first launch.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InsightsScreen(
    modifier: Modifier = Modifier
) {
    // On first launch, build a default canvas from local rules
    var currentCanvas by remember {
        mutableStateOf<InsightCanvas?>(null)
    }
    var isLoading by remember { mutableStateOf(true) }

    // Build initial canvas asynchronously
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val dataSource = InMemoryInsightDataSource()
        val digest = dataSource.buildDigest(
            com.openburnbar.data.insights.InsightFilter()
        )
        currentCanvas = LocalRuleBasedAdapter.buildCanvas(digest)
        isLoading = false
    }

    Surface(
        modifier = modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .padding(horizontal = AuroraSpacing.lg.dp)
        ) {
            // Header
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Text(
                text = "Insights",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "Visual dashboards for your AI spending",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            // Content
            if (isLoading) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        androidx.compose.material3.CircularProgressIndicator(
                            color = AuroraColors.purple
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            "Building your canvas...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else if (currentCanvas != null) {
                val canvas = currentCanvas!!
                InsightsCanvasGrid(
                    canvas = canvas,
                    selectedWidgetId = null,
                    onSelect = { /* TODO: inspector */ },
                    onMove = { _, _, _ -> /* TODO: drag-to-move */ },
                    onConfigure = { /* TODO: inspector */ },
                    onCitationTap = { /* TODO: citation drill-down */ }
                )
            } else {
                // Empty state
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "No insights yet.\nTap + to create a canvas.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                }
            }
        }
    }
}
