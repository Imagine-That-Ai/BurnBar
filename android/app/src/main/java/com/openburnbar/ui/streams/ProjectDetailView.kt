@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun ProjectDetailView(project: ProjectSummary, sessions: List<TokenUsage>, onSessionClick: (TokenUsage) -> Unit) {
    val topModels =
        sessions
            .groupBy { it.model ?: "Unknown" }
            .mapValues { (_, list) -> list.sumOf { it.totalTokens } }
            .toList()
            .sortedByDescending { it.second }
            .take(5)

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(vertical = AuroraSpacing.md.dp)
            .padding(bottom = AuroraSpacing.xxl.dp),
    ) {
        ProjectDetailHeroCard(project = project)
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        ProjectDetailStatRow(project = project, sessions = sessions, topModels = topModels)
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        ProjectDetailTopModelsCard(topModels = topModels)
        if (topModels.isNotEmpty()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        }
        ProjectDetailSessionsCard(sessions = sessions, onSessionClick = onSessionClick)
    }
}
