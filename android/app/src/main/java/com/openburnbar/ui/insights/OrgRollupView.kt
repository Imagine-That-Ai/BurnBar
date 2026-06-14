// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.models.OrgRollupRow
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

private data class OrgRollupScaffoldState(
    val isDark: Boolean,
    val enterpriseOrgViewEnabled: Boolean,
    val sharedPrefs: android.content.SharedPreferences,
    val selectedSegment: String,
    val selectedPeriod: String,
    val isLoading: Boolean,
    val rollupRows: List<OrgRollupRow>,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrgRollupView(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val database = remember { AppDatabase.getDatabase(context) }
    val dao = remember { database.budgetDatabaseAccess() }
    val sharedPrefs = remember(context) { orgRollupSharedPrefs(context) }

    var selectedSegment by remember { mutableStateOf("user") }
    var selectedPeriod by remember { mutableStateOf("month") }
    var rollupRows by remember { mutableStateOf<List<OrgRollupRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var enterpriseOrgViewEnabled by remember {
        mutableStateOf(sharedPrefs.getBoolean("enterpriseOrgViewEnabled", true))
    }

    LaunchedEffect(selectedSegment, selectedPeriod, enterpriseOrgViewEnabled) {
        if (!enterpriseOrgViewEnabled) return@LaunchedEffect
        isLoading = true
        rollupRows = fetchOrgRollupRows(dao, selectedSegment, selectedPeriod)
        isLoading = false
    }

    OrgRollupScaffold(
        modifier = modifier,
        state =
        OrgRollupScaffoldState(
            isDark = isDark,
            enterpriseOrgViewEnabled = enterpriseOrgViewEnabled,
            sharedPrefs = sharedPrefs,
            selectedSegment = selectedSegment,
            selectedPeriod = selectedPeriod,
            isLoading = isLoading,
            rollupRows = rollupRows,
        ),
        onEnableEnterprise = { enterpriseOrgViewEnabled = true },
        onSegmentSelected = { selectedSegment = it },
        onPeriodSelected = { selectedPeriod = it },
    )
}

@Composable
private fun OrgRollupScaffold(
    modifier: Modifier,
    state: OrgRollupScaffoldState,
    onEnableEnterprise: () -> Unit,
    onSegmentSelected: (String) -> Unit,
    onPeriodSelected: (String) -> Unit,
) {
    Column(
        modifier =
        modifier
            .fillMaxSize()
            .background(if (state.isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .padding(horizontal = AuroraSpacing.LG.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
        OrgRollupHeader(isDark = state.isDark)
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
        if (!state.enterpriseOrgViewEnabled) {
            OrgRollupLockedGate(
                sharedPrefs = state.sharedPrefs,
                onEnable = onEnableEnterprise,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
            return@Column
        }
        OrgRollupFilterBar(
            selectedSegment = state.selectedSegment,
            selectedPeriod = state.selectedPeriod,
            onSegmentSelected = onSegmentSelected,
            onPeriodSelected = onPeriodSelected,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
        OrgRollupContentBody(
            isLoading = state.isLoading,
            rollupRows = state.rollupRows,
            selectedSegment = state.selectedSegment,
            isDark = state.isDark,
            modifier = Modifier.fillMaxWidth().weight(1f),
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
    }
}
