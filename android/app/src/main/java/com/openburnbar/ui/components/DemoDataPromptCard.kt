package com.openburnbar.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Science
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun DemoDataPromptCard(
    modifier: Modifier = Modifier,
    isLoading: Boolean,
    message: String?,
    error: String?,
    onLoadDemoData: () -> Unit,
    onDismissStatus: () -> Unit
) {
    AuroraGlassCard(
        modifier = modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Science,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = AuroraColors.whimsy
                )
                Spacer(modifier = Modifier.size(AuroraSpacing.sm.dp))
                Text(
                    text = "Test without the Mac app",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
            Text(
                text = "Load a clearly labeled sample workspace into this Google account so closed testers can verify Pulse, Burn, Streams, quotas, and projects on Android.",
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (message != null || error != null) {
                Text(
                    text = message ?: error.orEmpty(),
                    fontSize = 12.sp,
                    color = if (error == null) AuroraColors.success else MaterialTheme.colorScheme.error
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Button(
                    onClick = onLoadDemoData,
                    enabled = !isLoading
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                        Spacer(modifier = Modifier.size(AuroraSpacing.xs.dp))
                    }
                    Text(if (isLoading) "Loading…" else "Load demo data")
                }
                if (message != null || error != null) {
                    OutlinedButton(onClick = onDismissStatus, enabled = !isLoading) {
                        Text("Dismiss")
                    }
                }
            }
        }
    }
}

@Composable
fun DemoDataEmptyState(
    modifier: Modifier = Modifier,
    isLoading: Boolean,
    message: String?,
    error: String?,
    onLoadDemoData: () -> Unit,
    onDismissStatus: () -> Unit
) {
    Column(
        modifier = modifier.fillMaxWidth().padding(AuroraSpacing.lg.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        EmptyStateView(
            icon = Icons.Filled.Science,
            title = "No Mac data yet",
            message = "This account has no synced Mac data. Closed testers can load a sample workspace instead."
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        DemoDataPromptCard(
            isLoading = isLoading,
            message = message,
            error = error,
            onLoadDemoData = onLoadDemoData,
            onDismissStatus = onDismissStatus
        )
    }
}
