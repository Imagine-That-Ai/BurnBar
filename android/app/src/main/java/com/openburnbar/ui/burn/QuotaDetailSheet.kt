// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.burn

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.ui.theme.AuroraSpacing

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuotaDetailSheet(providerKey: String, snapshots: List<ProviderQuotaSnapshot>, onDismiss: () -> Unit) {
    val provider = AgentProvider.fromKey(providerKey)
    val themeColor = provider?.let { Color(it.brandColor) } ?: MaterialTheme.colorScheme.onSurfaceVariant

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.LG.dp)
                .padding(bottom = AuroraSpacing.XXL.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            QuotaDetailSheetHero(
                provider = provider,
                providerKey = providerKey,
                accountCount = snapshots.size,
                themeColor = themeColor,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
            QuotaDetailStatsRow(snapshots = snapshots)
            Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
            snapshots.forEach { snapshot ->
                AccountQuotaCard(
                    snapshot = snapshot,
                    themeColor = themeColor,
                    provider = provider,
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
            }
        }
    }
}
