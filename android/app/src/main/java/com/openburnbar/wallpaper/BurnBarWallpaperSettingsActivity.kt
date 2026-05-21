package com.openburnbar.wallpaper

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

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

                    Column(modifier = Modifier.padding(16.dp)) {
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
                    }
                }
            }
        }
    }
}
