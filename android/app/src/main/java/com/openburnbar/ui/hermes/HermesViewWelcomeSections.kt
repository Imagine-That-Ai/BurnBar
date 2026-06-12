// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun WelcomeBlock(
    runtimeInfo: Map<String, String>,
    selectedModel: String,
    availableModels: List<String>,
    onModelSelect: (String) -> Unit,
    onTriggerPrompt: (String) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
        WelcomeBlockHeroCard(runtimeInfo = runtimeInfo, selectedModel = selectedModel)
        if (availableModels.isNotEmpty()) {
            Spacer(modifier = Modifier.height(16.dp))
            WelcomeBlockModelPicker(
                selectedModel = selectedModel,
                availableModels = availableModels,
                onModelSelect = onModelSelect,
            )
        }
        Spacer(modifier = Modifier.height(28.dp))
        WelcomeBlockSuggestedPrompts(onTriggerPrompt = onTriggerPrompt)
        Spacer(modifier = Modifier.height(20.dp))
        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.12f))
    }
}

@Composable
private fun WelcomeBlockHeroCard(runtimeInfo: Map<String, String>, selectedModel: String) {
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        border = BorderStroke(1.2.dp, glassStrokeBrush),
        modifier = Modifier.padding(horizontal = 16.dp),
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            WelcomeBlockMercuryAvatar()
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Hermes is ready",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = AuroraColors.hermesMercury,
            )
            if (runtimeInfo.isNotEmpty()) {
                Spacer(modifier = Modifier.height(12.dp))
                WelcomeBlockRuntimeBadges(runtimeInfo = runtimeInfo, selectedModel = selectedModel)
            }
        }
    }
}

@Composable
private fun WelcomeBlockModelPicker(
    selectedModel: String,
    availableModels: List<String>,
    onModelSelect: (String) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(availableModels.distinct()) { model ->
            val selected = model == selectedModel
            Surface(
                shape = RoundedCornerShape(percent = 50),
                color =
                    if (selected) {
                        AuroraColors.hermesMercury.copy(alpha = 0.22f)
                    } else {
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.25f)
                    },
                border =
                    BorderStroke(
                        width = 0.75.dp,
                        color =
                            if (selected) {
                                AuroraColors.hermesMercury.copy(alpha = 0.72f)
                            } else {
                                MaterialTheme.colorScheme.outline.copy(alpha = 0.22f)
                            },
                    ),
            ) {
                Row(
                    modifier =
                    Modifier
                        .clip(RoundedCornerShape(percent = 50))
                        .clickable { onModelSelect(model) }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    com.openburnbar.ui.components.ModelLogo(modelKey = model, size = 14.dp)
                    Text(
                        text = model,
                        fontSize = 12.sp,
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
    }
}

@Composable
private fun WelcomeBlockMercuryAvatar() {
    Box(
        modifier =
        Modifier
            .size(80.dp)
            .background(Brush.linearGradient(AuroraGradients.mercuryGradient), CircleShape)
            .padding(3.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(38.dp),
                tint = AuroraColors.hermesMercury,
            )
        }
    }
}

@Composable
private fun WelcomeBlockRuntimeBadges(runtimeInfo: Map<String, String>, selectedModel: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        runtimeInfo["host"]?.let { host ->
            Surface(
                shape = RoundedCornerShape(percent = 50),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                border = BorderStroke(0.75.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.22f)),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Computer,
                        contentDescription = null,
                        modifier = Modifier.size(13.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = host,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
        Surface(
            shape = RoundedCornerShape(percent = 50),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
            border = BorderStroke(0.75.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.22f)),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                com.openburnbar.ui.components.ModelLogo(modelKey = selectedModel, size = 13.dp)
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = selectedModel,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

@Composable
private fun WelcomeBlockSuggestedPrompts(onTriggerPrompt: (String) -> Unit) {
    val prompts =
        listOf(
            "What's my burn today?",
            "Show top providers",
            "Forecast my spend",
            "Analyze recent sessions",
        )
    Text(
        text = "SUGGESTED PROMPTS",
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(prompts) { prompt ->
            Surface(
                shape = RoundedCornerShape(percent = 50),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.25f),
                border = BorderStroke(0.75.dp, AuroraColors.hermesMercury.copy(alpha = 0.35f)),
                modifier = Modifier.padding(vertical = 4.dp),
            ) {
                Text(
                    text = prompt,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Medium,
                    modifier =
                    Modifier
                        .clip(RoundedCornerShape(percent = 50))
                        .clickable { onTriggerPrompt(prompt) }
                        .padding(horizontal = 14.dp, vertical = 9.dp),
                )
            }
        }
    }
}
