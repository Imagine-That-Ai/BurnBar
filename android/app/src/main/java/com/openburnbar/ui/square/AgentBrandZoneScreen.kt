package com.openburnbar.ui.square

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry

@Composable
fun AgentBrandZoneScreen(
    identity: AgentIdentity,
    registry: AgentIdentityRegistry,
    missionHost: MobileMissionConsoleHost,
    onOpenRuntimeThread: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    AgentBrandZoneScreenLayout(
        identity = identity,
        registry = registry,
        missionHost = missionHost,
        onOpenRuntimeThread = onOpenRuntimeThread,
        modifier = modifier,
    )
}
