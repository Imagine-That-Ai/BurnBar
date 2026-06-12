// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
internal fun DemoDataPromptHeader() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.Science,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = AuroraColors.whimsy,
        )
        Spacer(modifier = Modifier.size(AuroraSpacing.sm.dp))
        Text(
            text = "Test without the Mac app",
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
internal fun DemoDataPromptActions(
    isLoading: Boolean,
    message: String?,
    error: String?,
    onLoadDemoData: () -> Unit,
    onDismissStatus: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Button(onClick = onLoadDemoData, enabled = !isLoading) {
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
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
