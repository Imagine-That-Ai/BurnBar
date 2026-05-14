package com.openburnbar.ui.insights

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.services.FirestoreInsightDataSource
import com.openburnbar.data.insights.services.InsightDataSource
import kotlinx.coroutines.launch

/**
 * Host composable for the Android per-agent Insights surface.
 *
 * Owns the digest fetch and threading; `AgentInsightsScreen` stays pure.
 * Used by the nav host for both the agent-scoped route and the
 * aggregate route. The "Workspace" toolbar button routes the user back
 * to the legacy canvas screen for composer + canvas editing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentInsightsHost(
    scope: AgentInsightsScope,
    onOpenWorkspace: () -> Unit,
    onBack: () -> Unit,
    dataSource: InsightDataSource = remember { FirestoreInsightDataSource() }
) {
    var digest by remember { mutableStateOf<InsightDigest?>(null) }
    val coroutineScope = rememberCoroutineScope()

    LaunchedEffect(scope) {
        coroutineScope.launch {
            digest = try {
                dataSource.buildDigest(scope.window)
            } catch (_: Exception) {
                null
            }
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(scope.provider?.displayName ?: "All agents") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to roster")
                    }
                },
                actions = {
                    IconButton(onClick = onOpenWorkspace) {
                        Icon(Icons.Filled.GridView, contentDescription = "Open canvas workspace")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
            AgentInsightsScreen(
                scope = scope,
                digest = digest,
                analysis = null,
                canvases = emptyList(),
                onOpenWorkspace = onOpenWorkspace,
                contentPadding = padding
            )
        }
    }
}
