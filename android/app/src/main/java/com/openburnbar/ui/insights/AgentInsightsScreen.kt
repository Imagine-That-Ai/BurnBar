package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.data.models.AgentProvider

/**
 * Per-agent Insights detail on Android.
 *
 * Renders the same vertical stack as iOS/iPad/macOS:
 *   1. Header — provider identity (logo dot + name + status)
 *   2. KPI strip — Spend · Tokens · Sessions · Anomaly
 *   3. Brief — executive summary + findings count
 *   4. Mission rail — ranked High → Low
 *   5. Canvas grid — saved canvases scoped to this agent
 *
 * Inputs come from the host screen (digest + analysis + canvases),
 * the assembler does the scoping work, this composable only renders.
 */
@Composable
fun AgentInsightsScreen(
    scope: AgentInsightsScope,
    digest: InsightDigest?,
    analysis: InsightAnalysisResult?,
    canvases: List<InsightCanvas>,
    onOpenCanvas: (InsightCanvas) -> Unit = {},
    onTapMission: (InsightMissionCandidate) -> Unit = {},
    onOpenWorkspace: () -> Unit = {},
    contentPadding: PaddingValues = PaddingValues()
) {
    val bundle = remember(scope, digest, analysis, canvases) {
        AgentInsightsBundleAssembler.assemble(
            scope = scope,
            digest = digest,
            analysis = analysis,
            canvases = canvases
        )
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item { HeaderCard(header = bundle.header) }
        item { KPIStrip(strip = bundle.kpis) }
        bundle.brief?.let { brief ->
            item { BriefCard(brief = brief, onOpenWorkspace = onOpenWorkspace) }
        }
        if (bundle.missions.isNotEmpty()) {
            item { MissionRail(missions = bundle.missions, onTap = onTapMission) }
        }
        if (bundle.canvases.isNotEmpty()) {
            item { CanvasGridSection(canvases = bundle.canvases, onTap = onOpenCanvas) }
        }
        if (bundle.isEmpty) {
            item { EmptyState(header = bundle.header) }
        }
    }
}

// MARK: - Header

@Composable
private fun HeaderCard(header: AgentInsightsHeader) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(16.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (header.provider != null) {
                com.openburnbar.ui.components.ProviderLogo(
                    provider = header.provider,
                    size = 56.dp,
                )
            } else {
                Box(
                    modifier = Modifier.size(56.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = header.title.first().toString(),
                        style = MaterialTheme.typography.headlineSmall.copy(
                            fontWeight = FontWeight.Bold,
                            color = Color.White
                        )
                    )
                }
            }
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        header.title,
                        style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    StatusBadge(status = header.status)
                }
                header.subtitle?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                if (header.modelLineup.isNotEmpty()) {
                    Text(
                        header.modelLineup.joinToString(" · "),
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = FontFamily.Monospace
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusBadge(status: AgentInsightsHeader.Status) {
    val tint = when (status) {
        AgentInsightsHeader.Status.ACTIVE -> Color(0xFF22C55E)
        AgentInsightsHeader.Status.IDLE -> Color(0xFFEAB308)
        AgentInsightsHeader.Status.DORMANT -> MaterialTheme.colorScheme.onSurfaceVariant
        AgentInsightsHeader.Status.UNCONFIGURED -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(
        color = tint.copy(alpha = 0.15f),
        shape = RoundedCornerShape(50)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(tint))
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                status.displayLabel,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// MARK: - KPI strip

@Composable
private fun KPIStrip(strip: AgentInsightsKPIStrip) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.height(180.dp)
    ) {
        items(strip.ordered, key = { it.id }) { kpi ->
            KPITile(kpi = kpi)
        }
    }
}

@Composable
private fun KPITile(kpi: AgentInsightsKPIStrip.KPI) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(12.dp),
        tonalElevation = 1.dp
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(
                kpi.label.uppercase(),
                style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                kpi.valueText,
                style = MaterialTheme.typography.headlineMedium.copy(
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace
                )
            )
        }
    }
}

// MARK: - Brief

@Composable
private fun BriefCard(brief: InsightAnalysisResult, onOpenWorkspace: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth().clickable(onClick = onOpenWorkspace)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                "Editorial brief",
                style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                brief.executiveSummary,
                style = MaterialTheme.typography.bodyLarge
            )
            Spacer(modifier = Modifier.height(12.dp))
            Row {
                BriefStat(label = "Findings", count = brief.findings.size)
                Spacer(modifier = Modifier.width(16.dp))
                BriefStat(label = "Anomalies", count = brief.anomalies.size)
                Spacer(modifier = Modifier.width(16.dp))
                BriefStat(label = "Recs", count = brief.recommendations.size)
            }
        }
    }
}

@Composable
private fun BriefStat(label: String, count: Int) {
    Column {
        Text(
            count.toString(),
            style = MaterialTheme.typography.titleLarge.copy(
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace
            )
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// MARK: - Mission rail

@Composable
private fun MissionRail(missions: List<InsightMissionCandidate>, onTap: (InsightMissionCandidate) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp)) {
        Row {
            Text(
                "MISSIONS",
                style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                missions.size.toString(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(missions.size) { idx ->
                val mission = missions[idx]
                MissionCard(mission = mission, onTap = { onTap(mission) })
            }
        }
    }
}

@Composable
private fun MissionCard(mission: InsightMissionCandidate, onTap: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.width(260.dp).clickable(onClick = onTap)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            PriorityBadge(priority = mission.priority)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                mission.title,
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                mission.summary,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3
            )
        }
    }
}

@Composable
private fun PriorityBadge(priority: InsightMissionCandidate.Priority) {
    val (label, color) = when (priority) {
        InsightMissionCandidate.Priority.CRITICAL -> "Critical" to Color(0xFFEF4444)
        InsightMissionCandidate.Priority.HIGH -> "High" to Color(0xFFF45B69)
        InsightMissionCandidate.Priority.MEDIUM -> "Medium" to Color(0xFFEAB308)
        InsightMissionCandidate.Priority.LOW -> "Low" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(color = color, shape = RoundedCornerShape(50)) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
            color = Color.White,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
        )
    }
}

// MARK: - Canvas grid

@Composable
private fun CanvasGridSection(canvases: List<InsightCanvas>, onTap: (InsightCanvas) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp)) {
        Row {
            Text(
                "SAVED CANVASES",
                style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                canvases.size.toString(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.height(((canvases.size + 1) / 2 * 130).dp)
        ) {
            items(canvases, key = { it.id }) { canvas ->
                CanvasCard(canvas = canvas, onTap = { onTap(canvas) })
            }
        }
    }
}

@Composable
private fun CanvasCard(canvas: InsightCanvas, onTap: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().height(110.dp).clickable(onClick = onTap)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(
                canvas.widgets.size.toString(),
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                canvas.title,
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 2
            )
        }
    }
}

// MARK: - Empty state

@Composable
private fun EmptyState(header: AgentInsightsHeader) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(24.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                "No data yet for ${header.title}",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                "Run a session on this agent — the brief and KPIs will appear here automatically.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
