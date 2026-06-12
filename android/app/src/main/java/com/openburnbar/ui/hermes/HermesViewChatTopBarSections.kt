// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.BreathingDot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesChatTopBar(args: HermesChatTopBarArgs) {
    TopAppBar(
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = args.conversationTitle,
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                if (args.isConnected) BreathingDot(color = AuroraColors.success, size = 8)
            }
        },
        navigationIcon = {
            IconButton(onClick = {
                args.onDisconnect()
                args.onBack()
            }) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                )
            }
        },
        actions = {
            IconButton(onClick = args.onShowModelPicker) {
                Icon(Icons.Filled.Psychology, contentDescription = "Model")
            }
            IconButton(onClick = args.onShowConnectionSettings) {
                Icon(Icons.Filled.Settings, contentDescription = "Settings")
            }
            IconButton(onClick = args.onAgentPermissions) {
                Icon(Icons.Filled.Security, contentDescription = "Agent permissions")
            }
            HermesChatViewModeToggle(chatViewMode = args.chatViewMode, onToggleViewMode = args.onToggleViewMode)
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
    )
}

@Composable
private fun HermesChatViewModeToggle(chatViewMode: ChatViewMode, onToggleViewMode: () -> Unit) {
    val viewModeLabel = if (chatViewMode == ChatViewMode.CLI) "Agent view" else "CLI view"
    val viewModeIcon = if (chatViewMode == ChatViewMode.CLI) Icons.Filled.ChatBubble else Icons.Filled.Terminal
    IconButton(onClick = onToggleViewMode) {
        Icon(imageVector = viewModeIcon, contentDescription = viewModeLabel)
    }
}
