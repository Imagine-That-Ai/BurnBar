package com.openburnbar

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.openburnbar.menubar.MenuBarService
import com.openburnbar.menubar.SuppressionStore
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.theme.AuroraTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AuroraTheme {
                BurnBarNavHost()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (SuppressionStore.allowed(this)) {
            MenuBarService.start(this)
        }
    }
}
