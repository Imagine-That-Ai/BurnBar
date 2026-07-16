@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.openburnbar.wallpaper.livingthemes

import android.app.ActivityManager
import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.ui.components.MobileKernelBackdropThumbnail
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTheme

class LivingThemesActivity : ComponentActivity() {
    private val prefs by lazy {
        getSharedPreferences(LivingThemePrefs.NAME, Context.MODE_PRIVATE)
    }
    private var selectedTheme by mutableStateOf(LiveTheme.CONSTELLATION)
    private var selectedFps by mutableIntStateOf(LivingThemePrefs.DEFAULT_FPS)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        loadStoredSelection()
        applyRequest(intent)
        setContent {
            AuroraTheme {
                LivingThemesScreen(
                    selectedTheme = selectedTheme,
                    selectedFps = selectedFps,
                    onBack = ::finish,
                    onThemeSelected = ::selectTheme,
                    onFpsSelected = ::selectFps,
                    onSetWallpaper = ::openWallpaperPreview,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyRequest(intent)
    }

    private fun loadStoredSelection() {
        selectedTheme = LiveTheme.fromID(prefs.getString(LivingThemePrefs.KEY_THEME, null))
        selectedFps =
            prefs.getInt(LivingThemePrefs.KEY_FPS, LivingThemePrefs.DEFAULT_FPS)
                .coerceIn(5, 60)
    }

    private fun applyRequest(intent: Intent?) {
        val request = LivingThemeIntent.parse(intent?.dataString) ?: return
        selectTheme(request.theme)
        selectFps(request.maxFps)
    }

    private fun selectTheme(theme: LiveTheme) {
        selectedTheme = theme
        prefs.edit().putString(LivingThemePrefs.KEY_THEME, theme.id).apply()
    }

    private fun selectFps(fps: Int) {
        selectedFps = fps.coerceIn(5, 60)
        prefs.edit().putInt(LivingThemePrefs.KEY_FPS, selectedFps).apply()
    }

    private fun openWallpaperPreview() {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        if (activityManager.deviceConfigurationInfo.reqGlEsVersion < 0x30000) {
            Toast.makeText(
                this,
                "Living Themes require OpenGL ES 3.0 on this device.",
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        val intent =
            Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                putExtra(
                    WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                    ComponentName(this@LivingThemesActivity, LivingThemeWallpaperService::class.java),
                )
            }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER))
        }
    }
}

@Composable
private fun LivingThemesScreen(
    selectedTheme: LiveTheme,
    selectedFps: Int,
    onBack: () -> Unit,
    onThemeSelected: (LiveTheme) -> Unit,
    onFpsSelected: (Int) -> Unit,
    onSetWallpaper: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val themes =
        if (query.isBlank()) {
            LiveTheme.entries
        } else {
            LiveTheme.entries.filter { it.title.contains(query.trim(), ignoreCase = true) }
        }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Living Themes", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            LivingThemeHero(selectedTheme, selectedFps, onSetWallpaper)
            PowerProfileSelector(selectedFps, onFpsSelected)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                label = { Text("Search 42 living themes") },
            )
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(themes, key = { it.id }) { theme ->
                    LivingThemeCard(
                        theme = theme,
                        selected = theme == selectedTheme,
                        onClick = { onThemeSelected(theme) },
                    )
                }
                item { Spacer(Modifier.height(18.dp)) }
            }
        }
    }
}

@Composable
private fun LivingThemeHero(theme: LiveTheme, maxFps: Int, onSetWallpaper: () -> Unit) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(230.dp)
            .clip(RoundedCornerShape(24.dp)),
    ) {
        AndroidView(
            factory = { context ->
                LivingThemePreviewView(context).apply {
                    update(theme, maxFps)
                }
            },
            update = { preview -> preview.update(theme, maxFps) },
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.35f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.88f),
                    ),
                ),
        )
        Column(
            modifier = Modifier.align(Alignment.BottomStart).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(theme.title, color = Color.White, fontSize = 23.sp, fontWeight = FontWeight.Bold)
            Text(
                theme.backdropKernel.blurb,
                color = Color.White.copy(alpha = 0.74f),
                fontSize = 13.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Button(onClick = onSetWallpaper, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.LiveTv, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text("Preview & set live wallpaper", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun PowerProfileSelector(selectedFps: Int, onSelected: (Int) -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Power profile", fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(
                    if (selectedFps == 20) "Recommended" else "$selectedFps fps",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(20 to "Eco", 30 to "Atelier", 60 to "Cinema").forEach { (fps, label) ->
                    FilterChip(
                        selected = selectedFps == fps,
                        onClick = { onSelected(fps) },
                        label = { Text(label) },
                    )
                }
            }
            Text(
                "Pauses completely off-screen. Eco limits the wallpaper to 20 fps.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun LivingThemeCard(theme: LiveTheme, selected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = Color.Transparent,
        border =
        androidx.compose.foundation.BorderStroke(
            if (selected) 2.dp else 1.dp,
            if (selected) AuroraColors.ember else MaterialTheme.colorScheme.outlineVariant,
        ),
    ) {
        Box(modifier = Modifier.fillMaxWidth().height(118.dp)) {
            MobileKernelBackdropThumbnail(
                kernel = theme.backdropKernel,
                accentColor = AuroraColors.ember,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                modifier =
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0.4f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.84f),
                        ),
                    ),
            )
            Row(
                modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    theme.title,
                    modifier = Modifier.weight(1f),
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (selected) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = "Selected",
                        tint = AuroraColors.ember,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}
