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
fun ControlCenterScreen(
    modifier: Modifier = Modifier,
    store: ControlCenterStore = viewModel(),
    onBack: () -> Unit = {},
    onManagePlan: () -> Unit = {},
    onDomainDeepLink: (DataDomain, String) -> Unit = { _, _ -> },
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
    val isWide = LocalConfiguration.current.screenWidthDp >= 840

    val onDomainAction: (DataDomain, String) -> Unit = { domain, action ->
        if (action == ACTION_UPGRADE) onManagePlan() else onDomainDeepLink(domain, action)
    }

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
        Box(modifier = modifier.fillMaxSize().padding(innerPadding)) {
            if (isWide) {
                ControlCenterListDetail(
                    snapshot = snapshot,
                    isLoading = isLoading,
                    error = error,
                    store = store,
                    selectedDomainId = selectedDomainId,
                    onSelectDomain = { selectedDomainId = it?.ifBlank { null } },
                    onManagePlan = onManagePlan,
                    onDomainAction = onDomainAction,
                )
            } else {
                ControlCenterSinglePane(
                    snapshot = snapshot,
                    isLoading = isLoading,
                    error = error,
                    store = store,
                    selectedDomainId = selectedDomainId,
                    onSelectDomain = { selectedDomainId = it?.ifBlank { null } },
                    onManagePlan = onManagePlan,
                    onDomainAction = onDomainAction,
                )
            }
        }
    }
}

@Composable
private fun ControlCenterListDetail(
    snapshot: ControlCenterSnapshot,
    isLoading: Boolean,
    error: String?,
    store: ControlCenterStore,
    selectedDomainId: String?,
    onSelectDomain: (String?) -> Unit,
    onManagePlan: () -> Unit,
    onDomainAction: (DataDomain, String) -> Unit,
) {
    Row(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(0.42f).fillMaxHeight()) {
            ControlCenterInventoryList(
                snapshot = snapshot,
                isLoading = isLoading,
                error = error,
                store = store,
                selectedDomainId = selectedDomainId,
                onSelectDomain = onSelectDomain,
                onManagePlan = onManagePlan,
            )
        }
        VerticalDivider(
            color = PensieveControlTokens.glassLine,
            modifier = Modifier.fillMaxHeight(),
        )
        Box(modifier = Modifier.weight(0.58f).fillMaxHeight()) {
            val row = selectedDomainId?.let { store.row(it) }
            if (row != null) {
                DomainDetailPane(
                    domain = row.domain,
                    row = row,
                    tier = snapshot.tier,
                    store = store,
                    onDomainAction = onDomainAction,
                )
            } else {
                ControlCenterDetailPlaceholder()
            }
        }
    }
}

@Composable
private fun ControlCenterSinglePane(
    snapshot: ControlCenterSnapshot,
    isLoading: Boolean,
    error: String?,
    store: ControlCenterStore,
    selectedDomainId: String?,
    onSelectDomain: (String?) -> Unit,
    onManagePlan: () -> Unit,
    onDomainAction: (DataDomain, String) -> Unit,
) {
    val selectedRow = selectedDomainId?.let { store.row(it) }
    if (selectedRow != null) {
        // Phone: detail replaces the list; back-press handled by host nav.
        Column(modifier = Modifier.fillMaxSize()) {
            DomainBackBar(title = selectedRow.domain.title, onBack = { onSelectDomain("") })
            DomainDetailPane(
                domain = selectedRow.domain,
                row = selectedRow,
                tier = snapshot.tier,
                store = store,
                modifier = Modifier.weight(1f),
                onDomainAction = onDomainAction,
            )
        }
    } else {
        ControlCenterInventoryList(
            snapshot = snapshot,
            isLoading = isLoading,
            error = error,
            store = store,
            selectedDomainId = null,
            onSelectDomain = onSelectDomain,
            onManagePlan = onManagePlan,
        )
    }
}

@Composable
private fun ControlCenterInventoryList(
    snapshot: ControlCenterSnapshot,
    isLoading: Boolean,
    error: String?,
    store: ControlCenterStore,
    selectedDomainId: String?,
    onSelectDomain: (String?) -> Unit,
    onManagePlan: () -> Unit,
) {
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
        item { TierBand(tier = snapshot.tier, limits = snapshot.pensieveLimits, onManagePlan = onManagePlan) }
        error?.let { item { ControlCenterError(it, onDismiss = { store.clearError() }) } }
        item { BasinCard(snapshot = snapshot) }
        item {
            Text(
                "What we hold",
                style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                color = PensieveControlTokens.mercuryBright,
            )
        }
        items(snapshot.rows, key = { it.domain.id }) { row ->
            TransparencyInventoryItem(
                row = row,
                tier = snapshot.tier,
                selected = row.domain.id == selectedDomainId,
                onClick = { onSelectDomain(row.domain.id) },
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
