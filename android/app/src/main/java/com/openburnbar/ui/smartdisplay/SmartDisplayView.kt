// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Native Android port of iOS Views/SmartHub. Same information architecture
 * (Google smart displays + Pixel Clock), Aurora glass treatment everywhere.
 */
@Composable
fun SmartDisplayView(onBack: (() -> Unit)? = null) {
    val context = LocalContext.current
    val state by SmartHubBridgeClient.state.collectAsState()
    val isDark = isSystemInDarkTheme()

    DisposableEffect(Unit) {
        SmartHubBridgeClient.start(context)
        onDispose { SmartHubBridgeClient.stop() }
    }

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                    )
                }
            }
            Text(
                "Smart Displays",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = SmartHubBridgeClientCastActions::refresh) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh smart displays")
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        StatusFeedback(state)

        NestHubCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.lg.dp))

        PixelClockCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.xxxl.dp))
    }
}
