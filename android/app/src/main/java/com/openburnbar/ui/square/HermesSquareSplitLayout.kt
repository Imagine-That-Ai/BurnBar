package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.AssistantRuntimeID

// MARK: - Hermes Square Split Layout (Android parity, Hermes Square §6.11)
//
// Two-column adaptive layout for tablets / foldables: width ≥ 720dp
// shows the Square on the left and a detail pane on the right. Below
// that threshold delegates back to the single-column `HermesSquareScreen`.
//
// Compose Material 3 adaptive (`NavigationSuiteScaffold` /
// `ListDetailPaneScaffold`) is a dependency we don't ship in this app
// yet; this implementation uses `LocalConfiguration.screenWidthDp` so
// no extra dependency is required and the behavior is parity-equivalent.

@Composable
fun HermesSquareSplitLayout(
    onOpenLegacyRuntime: (AssistantRuntimeID) -> Unit = {},
    onOpenBrandZone: (String) -> Unit = {},
    modifier: Modifier = Modifier
) {
    val configuration = LocalConfiguration.current
    if (configuration.screenWidthDp < 720) {
        HermesSquareScreen(
            onOpenLegacyRuntime = onOpenLegacyRuntime,
            onOpenBrandZone = onOpenBrandZone
        )
        return
    }
    var detail: DetailRoute? by remember { mutableStateOf(null) }
    Row(modifier = modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(0.42f).fillMaxHeight()) {
            HermesSquareScreen(
                onOpenLegacyRuntime = { rt ->
                    detail = DetailRoute.RuntimeNative(rt)
                    onOpenLegacyRuntime(rt)
                },
                onOpenBrandZone = { uri ->
                    detail = DetailRoute.BrandZone(uri)
                    onOpenBrandZone(uri)
                }
            )
        }
        VerticalDivider(
            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.20f),
            modifier = Modifier
                .width(1.dp)
                .fillMaxHeight()
        )
        Box(modifier = Modifier.weight(0.58f).fillMaxHeight()) {
            when (val d = detail) {
                null -> SplitPlaceholder()
                is DetailRoute.BrandZone -> {
                    val registry = remember { com.openburnbar.data.square.AgentIdentityRegistry.shared() }
                    val identity = registry.identity(d.agentURI)
                    if (identity != null) {
                        AgentBrandZoneScreen(
                            identity = identity,
                            registry = registry,
                            missionHost = com.openburnbar.data.missions.MobileMissionConsoleHost.shared(),
                            modifier = Modifier.fillMaxSize()
                        )
                    } else SplitPlaceholder()
                }
                is DetailRoute.RuntimeNative -> SplitPlaceholder("Open ${d.runtime.token} on the left to expand here.")
                is DetailRoute.MissionDetail -> SplitPlaceholder("Mission detail: ${d.missionID}")
            }
        }
    }
}

@Composable
private fun SplitPlaceholder(message: String = "Pick a thread, mission, or pinned agent on the left.") {
    Column(
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxSize().padding(24.dp)
    ) {
        Text(
            "Hermes Square",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = androidx.compose.ui.Modifier.fillMaxWidth())
        Text(
            message,
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

internal sealed class DetailRoute {
    data class BrandZone(val agentURI: String) : DetailRoute()
    data class RuntimeNative(val runtime: AssistantRuntimeID) : DetailRoute()
    data class MissionDetail(val missionID: String) : DetailRoute()
}
