// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun ConversationListView(isConnected: Boolean, onStartChat: (String) -> Unit, onOpenLibrary: () -> Unit = {}, onOpenSetup: () -> Unit = {}) {
    Scaffold(
        topBar = {
            ConversationListTopBar(
                isConnected = isConnected,
                onOpenLibrary = onOpenLibrary,
                onOpenSetup = onOpenSetup,
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { onStartChat("New Chat") },
                containerColor = AuroraColors.hermesMercury,
            ) {
                Icon(Icons.Filled.Add, contentDescription = "New Chat", tint = Color.White)
            }
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            ConversationListEmptyHero(onStartChat = onStartChat)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationListTopBar(isConnected: Boolean, onOpenLibrary: () -> Unit, onOpenSetup: () -> Unit) {
    CenterAlignedTopAppBar(
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Hermes")
                Box(
                    modifier =
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(if (isConnected) AuroraColors.hermesMercury else MaterialTheme.colorScheme.error),
                )
            }
        },
        actions = {
            IconButton(onClick = onOpenLibrary) {
                Icon(Icons.Filled.History, contentDescription = "Library")
            }
            IconButton(onClick = onOpenSetup) {
                Icon(Icons.Filled.Settings, contentDescription = "Setup")
            }
        },
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent),
    )
}

@Composable
private fun ConversationListEmptyHero(onStartChat: (String) -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        AuroraGlassCard(modifier = Modifier.padding(AuroraSpacing.XL.dp)) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(modifier = Modifier.height(AuroraSpacing.XL.dp))
                Box(
                    modifier =
                    Modifier
                        .size(80.dp)
                        .clip(CircleShape)
                        .background(Brush.linearGradient(AuroraGradients.mercuryFoil)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Forum,
                        contentDescription = null,
                        modifier = Modifier.size(40.dp),
                        tint = Color.White,
                    )
                }
                Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
                Text(
                    text = "Start your first conversation",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
                Text(
                    text = "Hermes connects to your Mac to answer questions about your AI burn data.",
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
                Button(
                    onClick = { onStartChat("New Chat") },
                    colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesMercury),
                ) {
                    Text("Start Chat")
                }
            }
        }
    }
}
