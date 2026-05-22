package com.openburnbar.wallpaper

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider

class BurnBarWallpaperSettingsActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val prefs = getSharedPreferences("wallpaper_settings", Context.MODE_PRIVATE)

        setContent {
            MaterialTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    var pace by remember { mutableStateOf(prefs.getString("pace", "cinematic") ?: "cinematic") }
                    var shape by remember { mutableStateOf(prefs.getString("shape", "all") ?: "all") }
                    var customizeProviderGlyphs by remember { mutableStateOf(false) }
                    var providerGlyphs by remember { mutableStateOf(BurnBarWallpaperGlyphSettings.read(prefs)) }

                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp)
                    ) {
                        Text(text = "BurnBar Live Wallpaper Settings", style = MaterialTheme.typography.titleLarge)
                        Spacer(modifier = Modifier.height(24.dp))

                        Text(text = "Swarm Pace", style = MaterialTheme.typography.titleMedium)
                        Row {
                            RadioButton(selected = pace == "energetic", onClick = {
                                pace = "energetic"
                                prefs.edit().putString("pace", "energetic").apply()
                            })
                            Text("Energetic (Fast)", modifier = Modifier.padding(top = 12.dp))
                        }
                        Row {
                            RadioButton(selected = pace == "cinematic", onClick = {
                                pace = "cinematic"
                                prefs.edit().putString("pace", "cinematic").apply()
                            })
                            Text("Cinematic (Slow, Battery Friendly)", modifier = Modifier.padding(top = 12.dp))
                        }

                        Spacer(modifier = Modifier.height(24.dp))
                        Text(text = "Preferred Shape", style = MaterialTheme.typography.titleMedium)

                        val shapes = listOf(
                            "all" to "Cycle All Shapes",
                            "swarm" to "Just Swarm (No Shapes)",
                            "dollar" to "Dollar Sign ($)",
                            "code" to "Code Tags (</>)",
                            "xai" to "xAI Mark",
                            "grok" to "Grok Mark",
                            "providers" to "Provider Logo Swarm",
                            "rings" to "Rings",
                            "router" to "Router Flow"
                        )

                        shapes.forEach { (value, label) ->
                            Row {
                                RadioButton(selected = shape == value, onClick = {
                                    shape = value
                                    prefs.edit().putString("shape", value).apply()
                                })
                                Text(label, modifier = Modifier.padding(top = 12.dp))
                            }
                        }

                        Spacer(modifier = Modifier.height(24.dp))
                        OutlinedButton(onClick = { customizeProviderGlyphs = !customizeProviderGlyphs }) {
                            Text(providerGlyphSummary(providerGlyphs))
                        }

                        AnimatedVisibility(visible = customizeProviderGlyphs) {
                            Column(
                                modifier = Modifier
                                    .padding(top = 12.dp)
                                    .background(
                                        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
                                        RoundedCornerShape(16.dp)
                                    )
                                    .padding(12.dp)
                            ) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    TextButton(onClick = {
                                        providerGlyphs = AgentProvider.swarmGlyphProviders.toSet()
                                        BurnBarWallpaperGlyphSettings.write(prefs, providerGlyphs)
                                    }) {
                                        Text("All")
                                    }
                                    TextButton(onClick = {
                                        providerGlyphs = emptySet()
                                        BurnBarWallpaperGlyphSettings.write(prefs, providerGlyphs)
                                    }) {
                                        Text("None")
                                    }
                                }

                                AgentProvider.swarmGlyphProviders.forEach { provider ->
                                    Row(modifier = Modifier.fillMaxWidth()) {
                                        Checkbox(
                                            checked = providerGlyphs.contains(provider),
                                            onCheckedChange = { isChecked ->
                                                providerGlyphs = if (isChecked) {
                                                    providerGlyphs + provider
                                                } else {
                                                    providerGlyphs - provider
                                                }
                                                BurnBarWallpaperGlyphSettings.write(prefs, providerGlyphs)
                                            }
                                        )
                                        Surface(
                                            modifier = Modifier
                                                .padding(top = 13.dp, end = 8.dp)
                                                .size(8.dp),
                                            shape = RoundedCornerShape(4.dp),
                                            color = Color(provider.brandColor)
                                        ) {}
                                        Text(provider.displayName, modifier = Modifier.padding(top = 12.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun providerGlyphSummary(providers: Set<AgentProvider>): String {
        val total = AgentProvider.swarmGlyphProviders.size
        val count = providers.size
        return when (count) {
            total -> "Customize Provider Glyphs: All providers"
            0 -> "Customize Provider Glyphs: Provider logos hidden"
            else -> "Customize Provider Glyphs: $count/$total providers"
        }
    }
}
