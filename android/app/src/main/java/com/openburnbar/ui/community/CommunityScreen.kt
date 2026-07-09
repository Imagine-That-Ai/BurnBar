package com.openburnbar.ui.community

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.community.CommunityTimeWindow
import com.openburnbar.data.community.ConsentTriState
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun CommunityScreen(viewModel: CommunityViewModel = viewModel(), modifier: Modifier = Modifier) {
    val uiState by viewModel.uiState.collectAsState()
    val consentDraft by viewModel.consentDraft.collectAsState()
    val context = LocalContext.current
    val coarseLocationLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                viewModel.joinCommunity()
            } else {
                viewModel.declineCityLocationPermission()
            }
        }
    fun saveCommunityPreferences() {
        val needsCityPermission =
            consentDraft.l2City == ConsentTriState.GRANTED &&
                consentDraft.locationConsent == ConsentTriState.GRANTED &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ) != PackageManager.PERMISSION_GRANTED
        if (needsCityPermission) {
            coarseLocationLauncher.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
        } else {
            viewModel.joinCommunity()
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        AuroraBackdrop()
        Column(
            modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(AuroraSpacing.LG.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        ) {
            Text(
                text = "Community",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )

            if (uiState.isLoading) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            uiState.error?.let { msg ->
                ErrorStateView(title = "Community", message = msg, onRetry = { viewModel.refresh() })
            }

            uiState.actionMessage?.let { msg ->
                Text(
                    text = msg,
                    style = AuroraType.caption,
                    color = AuroraColors.success,
                    modifier = Modifier.padding(bottom = AuroraSpacing.XS.dp),
                )
            }

            CommunityPersonalHero(
                tokens = uiState.heroTokens,
                costUsd = uiState.heroCostUsd,
                modelMix = uiState.modelMix,
            )

            CommunityTimeFilterRow(
                selected = uiState.selectedWindow,
                onSelect = viewModel::setTimeWindow,
            )

            uiState.leaderboardCards.forEach { card ->
                CommunityLeaderboardCard(
                    state = card,
                    anonId = uiState.profile?.anonId,
                )
            }

            CommunityPercentileStrip(percentiles = uiState.percentiles)

            CommunityPeerComparisonChart(
                cohortSize = uiState.cohortSize,
                percentiles = uiState.percentiles,
                yourTokens = uiState.heroTokens,
            )

            CommunityPurposeBreakdown(purposeMix = uiState.purposeMix)

            CommunityConsentCenter(
                draft = consentDraft,
                hasJoined = uiState.hasJoined,
                isJoining = uiState.isJoining,
                isRevoking = uiState.isRevoking,
                isExportingLookingGlass = uiState.isExportingLookingGlass,
                lookingGlassExportUrl = uiState.lookingGlassExportUrl,
                onDraftChange = { newDraft -> viewModel.updateConsentDraft { _ -> newDraft } },
                onSave = { saveCommunityPreferences() },
                onRevoke = { viewModel.revokeParticipation() },
                onExportLookingGlass = { viewModel.exportLookingGlassBundle() },
                onOpenLookingGlassExport = { url ->
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    }
                },
            )
        }
    }
}

@Composable
private fun CommunityPersonalHero(tokens: Long, costUsd: Double, modelMix: Map<String, Double>) {
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.XL,
        contentPadding = AuroraSpacing.LG.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(text = "Your burn", style = AuroraType.headline)
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp)) {
                Column {
                    Text(
                        text = formatCompact(tokens) + " tokens",
                        style = AuroraType.displayLarge.copy(fontWeight = FontWeight.Bold),
                    )
                    Text(
                        text = "$${"%.2f".format(costUsd)}",
                        style = AuroraType.body,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (modelMix.isNotEmpty()) {
                Text(text = "Model mix", style = AuroraType.caption)
                modelMix.entries.sortedByDescending { it.value }.take(4).forEach { (model, share) ->
                    Text(
                        text = "${model.take(24)} — ${(share * 100).toInt()}%",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun CommunityTimeFilterRow(selected: CommunityTimeWindow, onSelect: (CommunityTimeWindow) -> Unit) {
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
    ) {
        CommunityTimeWindow.entries.forEach { window ->
            FilterChip(
                selected = window == selected,
                onClick = { onSelect(window) },
                label = { Text(window.label) },
            )
        }
    }
}

@Composable
private fun CommunityPercentileStrip(percentiles: com.openburnbar.data.models.generated.FirestorePercentileBands) {
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.LG,
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(text = "Where you stand", style = AuroraType.headline)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                PercentileChip("p50", percentiles.p50)
                PercentileChip("p75", percentiles.p75)
                PercentileChip("p90", percentiles.p90)
                PercentileChip("p99", percentiles.p99)
            }
        }
    }
}

@Composable
private fun PercentileChip(label: String, value: Double) {
    Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
        Text(text = label, style = AuroraType.tiny, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text = formatCompact(value.toLong()), style = AuroraType.caption, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun CommunityPeerComparisonChart(cohortSize: Long, percentiles: com.openburnbar.data.models.generated.FirestorePercentileBands, yourTokens: Long) {
    if (!shouldShowPeerComparisonChart(cohortSize, percentiles, yourTokens)) return
    val sparkline = peerComparisonSparklineData(percentiles, yourTokens) ?: return
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.LG,
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(text = "Peer comparison", style = AuroraType.headline)
            Text(
                text = "Anonymized cohort of $cohortSize burners — p50/p75/p90/p99 bands with your burn.",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            AuroraSparkline(
                data = sparkline,
                modifier = Modifier.fillMaxWidth().padding(top = AuroraSpacing.SM.dp),
                strokeColor = AuroraColors.whimsy,
            )
        }
    }
}

@Composable
private fun CommunityPurposeBreakdown(purposeMix: Map<String, Double>) {
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.LG,
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
            Text(text = "Purpose breakdown", style = AuroraType.headline)
            if (purposeMix.isEmpty()) {
                Text(
                    text = "Purpose mix appears as sessions are classified.",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                purposeMix.entries.sortedByDescending { it.value }.forEach { (purpose, share) ->
                    Text(
                        text = "${purpose.replaceFirstChar { it.titlecase() }} — ${(share * 100).toInt()}%",
                        style = AuroraType.caption,
                    )
                }
            }
        }
    }
}

private fun formatCompact(value: Long): String = when {
    value >= 1_000_000 -> "%.1fM".format(value / 1_000_000.0)
    value >= 1_000 -> "%.1fK".format(value / 1_000.0)
    else -> value.toString()
}
