@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.domains.DataDomain
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Data & Privacy Control Center — the single surface where a member sees every
 * data domain BurnBar holds, how each is sealed, its live footprint, and the
 * controls to export, delete, recover, audit, or panic-revoke.
 *
 * Adaptive layout: ≥ 840dp shows a list-detail split (inventory left, detail
 * right) — the same width-threshold pattern `HermesSquareSplitLayout` uses,
 * since this app does not ship the Material 3 adaptive
 * (`NavigationSuiteScaffold` / `ListDetailPaneScaffold`) dependency. Below the
 * threshold it's a single scrolling column; tapping a domain pushes its detail
 * via the host's [onOpenDomain] (or expands inline when no host route exists).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ControlCenterScreen(
    modifier: Modifier = Modifier,
    store: ControlCenterStore = viewModel(),
    onBack: () -> Unit = {},
    onManagePlan: () -> Unit = {},
    onDomainDeepLink: (DataDomain, String) -> Unit = { _, _ -> },
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String? = { null },
) {
    LaunchedEffect(Unit) {
        store.refresh()
        store.loadRecovery()
        store.loadAudit(reset = true)
    }

    val snapshot by store.snapshot.collectAsState()
    val isLoading by store.isLoading.collectAsState()
    val error by store.error.collectAsState()

    var selectedDomainId by remember { mutableStateOf<String?>(null) }
    var unlockFeature by remember { mutableStateOf<com.openburnbar.ui.pro.GatedFeature?>(null) }
    val isWide = LocalConfiguration.current.screenWidthDp >= 840

    val onDomainAction: (DataDomain, String) -> Unit = { domain, action ->
        if (action == ACTION_UPGRADE) {
            // Route an upgrade tap through the evocative unlock sheet when this
            // domain fronts a marquee gated feature; otherwise fall back to the
            // plain manage-plan deep link.
            val feature = gatedFeatureForDomain(domain.id)
            if (feature != null) unlockFeature = feature else onManagePlan()
        } else {
            onDomainDeepLink(domain, action)
        }
    }
    val onUnlock: (com.openburnbar.ui.pro.GatedFeature) -> Unit = { unlockFeature = it }
    val paneState = ControlCenterPaneState(snapshot, isLoading, error, selectedDomainId)
    val paneCallbacks = ControlCenterPaneCallbacks(
        onSelectDomain = { selectedDomainId = it?.ifBlank { null } },
        onManagePlan = onManagePlan,
        onDomainAction = onDomainAction,
        onUnlock = onUnlock,
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Data & Privacy", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        ControlCenterPaneHost(
            modifier = modifier.padding(innerPadding),
            isWide = isWide,
            paneState = paneState,
            store = store,
            callbacks = paneCallbacks,
        )
    }

    ControlCenterUnlockSheet(
        unlockFeature = unlockFeature,
        priceForTier = priceForTier,
        onUnlock = onManagePlan,
        onDismiss = { unlockFeature = null },
    )
}

@Composable
private fun ControlCenterPaneHost(
    modifier: Modifier,
    isWide: Boolean,
    paneState: ControlCenterPaneState,
    store: ControlCenterStore,
    callbacks: ControlCenterPaneCallbacks,
) {
    Box(modifier = modifier.fillMaxSize()) {
        if (isWide) {
            ControlCenterListDetail(
                paneState = paneState,
                store = store,
                callbacks = callbacks,
            )
        } else {
            ControlCenterSinglePane(
                paneState = paneState,
                store = store,
                callbacks = callbacks,
            )
        }
    }
}

@Composable
private fun ControlCenterUnlockSheet(
    unlockFeature: com.openburnbar.ui.pro.GatedFeature?,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String?,
    onUnlock: () -> Unit,
    onDismiss: () -> Unit,
) {
    com.openburnbar.ui.pro.FeatureUnlockSheet(
        feature = unlockFeature ?: com.openburnbar.ui.pro.GatedFeatureCatalog.feature(com.openburnbar.ui.pro.GatedFeatureID.DATA_VAULT),
        show = unlockFeature != null,
        livePrice = unlockFeature?.let { priceForTier(it.requiredTier) },
        onUnlock = onUnlock,
        onDismiss = onDismiss,
    )
}

private data class ControlCenterPaneState(
    val snapshot: ControlCenterSnapshot,
    val isLoading: Boolean,
    val error: String?,
    val selectedDomainId: String?,
)

private data class ControlCenterPaneCallbacks(
    val onSelectDomain: (String?) -> Unit,
    val onManagePlan: () -> Unit,
    val onDomainAction: (DataDomain, String) -> Unit,
    val onUnlock: (com.openburnbar.ui.pro.GatedFeature) -> Unit,
)

@Composable
private fun ControlCenterListDetail(
    paneState: ControlCenterPaneState,
    store: ControlCenterStore,
    callbacks: ControlCenterPaneCallbacks,
) {
    Row(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(0.42f).fillMaxHeight()) {
            ControlCenterInventoryList(
                paneState = paneState,
                store = store,
                callbacks = callbacks,
            )
        }
        VerticalDivider(
            color = PensieveControlTokens.glassLine,
            modifier = Modifier.fillMaxHeight(),
        )
        Box(modifier = Modifier.weight(0.58f).fillMaxHeight()) {
            val row = paneState.selectedDomainId?.let { store.row(it) }
            if (row != null) {
                DomainDetailPane(
                    domain = row.domain,
                    row = row,
                    tier = paneState.snapshot.tier,
                    store = store,
                    onDomainAction = callbacks.onDomainAction,
                )
            } else {
                ControlCenterDetailPlaceholder()
            }
        }
    }
}

@Composable
private fun ControlCenterSinglePane(
    paneState: ControlCenterPaneState,
    store: ControlCenterStore,
    callbacks: ControlCenterPaneCallbacks,
) {
    val selectedRow = paneState.selectedDomainId?.let { store.row(it) }
    if (selectedRow != null) {
        // Phone: detail replaces the list; back-press handled by host nav.
        Column(modifier = Modifier.fillMaxSize()) {
            DomainBackBar(title = selectedRow.domain.title, onBack = { callbacks.onSelectDomain("") })
            DomainDetailPane(
                domain = selectedRow.domain,
                row = selectedRow,
                tier = paneState.snapshot.tier,
                store = store,
                modifier = Modifier.weight(1f),
                onDomainAction = callbacks.onDomainAction,
            )
        }
    } else {
        ControlCenterInventoryList(
            paneState = paneState.copy(selectedDomainId = null),
            store = store,
            callbacks = callbacks,
        )
    }
}

@Composable
private fun ControlCenterInventoryList(
    paneState: ControlCenterPaneState,
    store: ControlCenterStore,
    callbacks: ControlCenterPaneCallbacks,
) {
    val snapshot = paneState.snapshot
    val recovery by store.recoveryMethods.collectAsState()
    val recoveryBusy by store.recoveryBusy.collectAsState()
    val panicBusy by store.panicBusy.collectAsState()
    val panicResult by store.lastPanicResult.collectAsState()
    val auditEvents by store.auditEvents.collectAsState()
    val auditLoading by store.auditLoading.collectAsState()
    val auditCursor by store.auditCursor.collectAsState()
    val auditVerification by store.auditVerification.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        item { TierBand(tier = snapshot.tier, limits = snapshot.pensieveLimits, onManagePlan = callbacks.onManagePlan) }
        paneState.error?.let { item { ControlCenterError(it, onDismiss = { store.clearError() }) } }
        item { BasinCard(snapshot = snapshot) }
        item { ControlCenterInventoryHeading() }
        items(snapshot.rows, key = { it.domain.id }) { row ->
            TransparencyInventoryItem(
                row = row,
                tier = snapshot.tier,
                selected = row.domain.id == paneState.selectedDomainId,
                onClick = { callbacks.onSelectDomain(row.domain.id) },
                onUnlock = callbacks.onUnlock,
            )
        }
        item {
            RecoverySection(
                methods = recovery,
                busy = recoveryBusy,
                onSetupKey = { store.setupRecovery("recovery_key", emptyMap()) },
                onSetupContact = { store.setupRecovery("recovery_contact", emptyMap()) },
                onConfirm = { store.confirmRecovery(it) },
            )
        }
        item {
            AuditTimelineSection(
                events = auditEvents,
                loading = auditLoading,
                hasMore = auditCursor != null,
                verification = auditVerification,
                onVerify = { store.verifyAudit() },
                onLoadMore = { store.loadAudit(reset = false) },
            )
        }
        item {
            PanicSection(
                busy = panicBusy,
                lastResult = panicResult,
                onRevoke = { store.revokeAllAccess(it) },
            )
        }
    }
}

@Composable
private fun ControlCenterInventoryHeading() {
    Text(
        "What we hold",
        style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
        color = PensieveControlTokens.mercuryBright,
    )
}

@Composable
private fun TierBand(tier: DataTier, limits: PensieveLimits?, onManagePlan: () -> Unit) {
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "You're on ${tier.label}",
                    style = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
                    color = PensieveControlTokens.mercuryBright,
                )
                androidx.compose.foundation.layout.Spacer(modifier = Modifier.weight(1f))
                // Android control surface uses manage / deep-link only — no in-app purchase here.
                Text(
                    "Manage plan",
                    style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = PensieveControlTokens.brassBright,
                    modifier = Modifier.clickableText(onManagePlan),
                )
            }
            limits?.let {
                Text(
                    "Pensieve: up to ${it.sources} sources · ${formatCount(it.chunks)} memories · ${formatBytes(it.bytes)}.",
                    style = AuroraType.caption,
                    color = PensieveControlTokens.textMute,
                )
            }
        }
    }
}

@Composable
private fun ControlCenterError(message: String, onDismiss: () -> Unit) {
    AuroraGlassCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(message, style = AuroraType.caption, color = PensieveControlTokens.sealCrimson, modifier = Modifier.weight(1f))
            Text(
                "Dismiss",
                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = PensieveControlTokens.textMute,
                modifier = Modifier.clickableText(onDismiss),
            )
        }
    }
}

@Composable
private fun ControlCenterDetailPlaceholder() {
    Column(
        modifier = Modifier.fillMaxSize().padding(AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "Pick a domain",
            style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
            color = PensieveControlTokens.mercuryBright,
        )
        Text(
            "Choose anything on the left to see exactly what's stored, how it's sealed, and your controls.",
            style = AuroraType.caption,
            color = PensieveControlTokens.textMute,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DomainBackBar(title: String, onBack: () -> Unit) {
    TopAppBar(
        title = { Text(title, fontWeight = FontWeight.SemiBold) },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to inventory")
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
    )
}

private fun Modifier.clickableText(onClick: () -> Unit): Modifier = this.clickable(onClick = onClick)

/** Internal action token routed up to the host when a locked domain wants upgrade. */
internal const val ACTION_UPGRADE = "__upgrade__"
