package com.openburnbar.ui.settings

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TextExpansionSettingsScreen(onBack: () -> Unit) {
    val state = rememberTextExpansionSettingsState()
    TextExpansionSettingsScreenContent(onBack = onBack, state = state)
}
