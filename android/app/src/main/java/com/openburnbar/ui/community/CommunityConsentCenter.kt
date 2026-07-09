package com.openburnbar.ui.community

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.openburnbar.data.community.CommunityConsentDraft
import com.openburnbar.data.community.ConsentTriState
import com.openburnbar.ui.components.AuroraButton
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun CommunityConsentCenter(
    draft: CommunityConsentDraft,
    hasJoined: Boolean,
    isJoining: Boolean,
    isRevoking: Boolean,
    onDraftChange: (CommunityConsentDraft) -> Unit,
    onSave: () -> Unit,
    onRevoke: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AuroraGlassCard(
        modifier = modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.LG,
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
            Text(
                text = "Consent center",
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Three ladders: private analytics stay on-device, rankings are geography-tiered, " +
                    "and Looking Glass exports richer traces without feeding leaderboards.",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            CommunityTriStateRow(
                icon = Icons.Outlined.VisibilityOff,
                label = "L1 — Private analytics",
                subtitle = "Local-only dashboard. No egress.",
                checked = draft.l1Analytics == ConsentTriState.GRANTED,
                onCheckedChange = { on ->
                    onDraftChange(
                        draft.copy(
                            l1Analytics = if (on) ConsentTriState.GRANTED else ConsentTriState.DECLINED,
                        ),
                    )
                },
            )

            CommunityTriStateRow(
                icon = Icons.Outlined.Visibility,
                label = "L2 — Community rankings",
                subtitle = "Anonymized leaderboards per geography tier.",
                checked = draft.l2Rankings == ConsentTriState.GRANTED,
                onCheckedChange = { on ->
                    val granted = if (on) ConsentTriState.GRANTED else ConsentTriState.DECLINED
                    onDraftChange(
                        draft.copy(
                            l2Rankings = granted,
                            l2World = if (on) ConsentTriState.GRANTED else draft.l2World,
                        ),
                    )
                },
            )

            if (draft.l2Rankings == ConsentTriState.GRANTED) {
                Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
                    CommunityTierToggle("World", draft.l2World == ConsentTriState.GRANTED) { on ->
                        onDraftChange(draft.copy(l2World = tierFromToggle(on)))
                    }
                    CommunityTierToggle("Country", draft.l2Country == ConsentTriState.GRANTED) { on ->
                        onDraftChange(draft.copy(l2Country = tierFromToggle(on)))
                    }
                    CommunityTierToggle("Region", draft.l2Region == ConsentTriState.GRANTED) { on ->
                        onDraftChange(draft.copy(l2Region = tierFromToggle(on)))
                    }
                    CommunityTierToggle("City", draft.l2City == ConsentTriState.GRANTED) { on ->
                        onDraftChange(draft.copy(l2City = tierFromToggle(on)))
                    }
                    CommunityTriStateRow(
                        icon = Icons.Outlined.Visibility,
                        label = "Coarse location",
                        subtitle = "Required for city-tier rankings.",
                        checked = draft.locationConsent == ConsentTriState.GRANTED,
                        onCheckedChange = { on ->
                            onDraftChange(
                                draft.copy(
                                    locationConsent = if (on) ConsentTriState.GRANTED else ConsentTriState.DECLINED,
                                ),
                            )
                        },
                    )
                }
            }

            CommunityTriStateRow(
                icon = Icons.Outlined.Visibility,
                label = "L3 — Looking Glass",
                subtitle = "Export bundles for research. Never used on leaderboards.",
                checked = draft.l3LookingGlass == ConsentTriState.GRANTED,
                onCheckedChange = { on ->
                    onDraftChange(
                        draft.copy(
                            l3LookingGlass = if (on) ConsentTriState.GRANTED else ConsentTriState.DECLINED,
                        ),
                    )
                },
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
            ) {
                AuroraButton(
                    onClick = onSave,
                    enabled = !isJoining,
                    loading = isJoining,
                    modifier = Modifier.weight(1f),
                ) {
                    Text(if (hasJoined) "Update consent" else "Join community")
                }
                if (hasJoined) {
                    AuroraSecondaryButton(
                        onClick = onRevoke,
                        enabled = !isRevoking,
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(if (isRevoking) "Pausing…" else "Pause & revoke")
                    }
                }
            }
        }
    }
}

@Composable
private fun CommunityTierToggle(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = AuroraSpacing.LG.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = label, style = AuroraType.caption)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun CommunityTriStateRow(icon: ImageVector, label: String, subtitle: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = label, style = AuroraType.body)
            Text(text = subtitle, style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

private fun tierFromToggle(on: Boolean): ConsentTriState = if (on) ConsentTriState.GRANTED else ConsentTriState.DECLINED
