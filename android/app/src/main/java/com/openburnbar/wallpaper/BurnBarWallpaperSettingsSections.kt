package com.openburnbar.wallpaper

import android.content.SharedPreferences
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes

@Composable
internal fun WallpaperPaceSection(pace: String, onPaceChange: (String) -> Unit) {
    Text(text = "Swarm Pace", style = MaterialTheme.typography.titleMedium)
    Row {
        RadioButton(selected = pace == "energetic", onClick = { onPaceChange("energetic") })
        Text("Energetic (Fast)", modifier = Modifier.padding(top = 12.dp))
    }
    Row {
        RadioButton(selected = pace == "cinematic", onClick = { onPaceChange("cinematic") })
        Text("Cinematic (Slow, Battery Friendly)", modifier = Modifier.padding(top = 12.dp))
    }
}

@Composable
internal fun WallpaperShapeSection(shape: String, onShapeChange: (String) -> Unit) {
    Text(text = "Preferred Shape", style = MaterialTheme.typography.titleMedium)
    val shapes =
        listOf(
            "all" to "Cycle All Shapes",
            "swarm" to "Just Swarm (No Shapes)",
            "dollar" to "Dollar Sign ($)",
            "code" to "Code Tags (</>)",
            "xai" to "xAI Mark",
            "grok" to "Grok Mark",
            "providers" to "Provider Logo Swarm",
            "rings" to "Rings",
            "router" to "Router Flow",
        )
    shapes.forEach { (value, label) ->
        Row {
            RadioButton(selected = shape == value, onClick = { onShapeChange(value) })
            Text(label, modifier = Modifier.padding(top = 12.dp))
        }
    }
}

@Composable
internal fun WallpaperProviderGlyphSection(
    prefs: SharedPreferences,
    customizeProviderGlyphs: Boolean,
    providerGlyphs: Set<AgentProvider>,
    onCustomizeToggle: () -> Unit,
    onProviderGlyphsChange: (Set<AgentProvider>) -> Unit,
) {
    OutlinedButton(onClick = onCustomizeToggle) {
        Text(providerGlyphSummary(providerGlyphs))
    }

    AnimatedVisibility(visible = customizeProviderGlyphs) {
        WallpaperProviderGlyphPicker(
            prefs = prefs,
            providerGlyphs = providerGlyphs,
            onProviderGlyphsChange = onProviderGlyphsChange,
        )
    }
}

@Composable
private fun WallpaperProviderGlyphPicker(
    prefs: SharedPreferences,
    providerGlyphs: Set<AgentProvider>,
    onProviderGlyphsChange: (Set<AgentProvider>) -> Unit,
) {
    Column(
        modifier =
        Modifier
            .padding(top = 12.dp)
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
                RoundedCornerShape(16.dp),
            )
            .padding(12.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = {
                onProviderGlyphsChange(AgentProvider.swarmGlyphProviders.toSet())
                BurnBarWallpaperGlyphSettings.write(prefs, AgentProvider.swarmGlyphProviders.toSet())
            }) {
                Text("All")
            }
            TextButton(onClick = {
                onProviderGlyphsChange(emptySet())
                BurnBarWallpaperGlyphSettings.write(prefs, emptySet())
            }) {
                Text("None")
            }
        }

        AgentProvider.swarmGlyphProviders.forEach { provider ->
            Row(modifier = Modifier.fillMaxWidth()) {
                Checkbox(
                    checked = providerGlyphs.contains(provider),
                    onCheckedChange = { isChecked ->
                        val updated =
                            if (isChecked) {
                                providerGlyphs + provider
                            } else {
                                providerGlyphs - provider
                            }
                        onProviderGlyphsChange(updated)
                        BurnBarWallpaperGlyphSettings.write(prefs, updated)
                    },
                )
                Image(
                    painter = painterResource(id = provider.logoRes),
                    contentDescription = provider.displayName,
                    modifier =
                    Modifier
                        .padding(top = 10.dp, end = 8.dp)
                        .size(20.dp)
                        .clip(RoundedCornerShape(4.dp)),
                    contentScale = ContentScale.Fit,
                )
                Text(provider.displayName, modifier = Modifier.padding(top = 12.dp))
            }
        }
    }
}

internal fun providerGlyphSummary(providers: Set<AgentProvider>): String {
    val total = AgentProvider.swarmGlyphProviders.size
    val count = providers.size
    return when (count) {
        total -> "Customize Provider Glyphs: All providers"
        0 -> "Customize Provider Glyphs: Provider logos hidden"
        else -> "Customize Provider Glyphs: $count/$total providers"
    }
}
