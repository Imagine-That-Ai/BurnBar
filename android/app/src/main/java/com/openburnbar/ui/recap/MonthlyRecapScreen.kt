package com.openburnbar.ui.recap

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.recap.MonthlyRecap
import com.openburnbar.data.recap.RecapCard
import com.openburnbar.data.recap.RecapEnvironment
import com.openburnbar.data.recap.RecapPhase
import com.openburnbar.data.recap.RecapWindow
import com.openburnbar.ui.theme.AuroraColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MonthlyRecapScreen(onDismiss: (() -> Unit)? = null, viewModel: RecapEnvironment? = null) {
    val context = LocalContext.current
    val env = remember(context) { viewModel ?: RecapEnvironment(context) }
    val phase by env.phase.collectAsState()
    val selectedMonth by env.selectedMonth.collectAsState()
    val availableMonths by env.availableMonths.collectAsState()

    Scaffold(
        topBar = {
            RecapTopBar(
                selectedMonth = selectedMonth,
                availableMonths = availableMonths,
                onSelectMonth = { env.selectMonth(it) },
                onDismiss = onDismiss,
            )
        },
        containerColor = AuroraColors.lightBackground,
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            when (val currentPhase = phase) {
                is RecapPhase.Idle, is RecapPhase.Building -> RecapLoadingContent()
                is RecapPhase.NotEnoughData -> RecapNotEnoughDataContent(currentPhase.window) {
                    env.load(currentPhase.window, forceRegenerate = true)
                }
                is RecapPhase.Failed -> RecapFailedContent(currentPhase.message) {
                    env.load(selectedMonth, forceRegenerate = true)
                }
                is RecapPhase.Ready -> RecapReadyContent(
                    recap = currentPhase.recap,
                    context = context,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecapTopBar(selectedMonth: RecapWindow, availableMonths: List<RecapWindow>, onSelectMonth: (RecapWindow) -> Unit, onDismiss: (() -> Unit)?) {
    var showMonthMenu by remember { mutableStateOf(false) }

    TopAppBar(
        title = {
            Text(
                text = "Monthly Recap",
                style = RecapTheme.Typography.cardHeadline,
                color = AuroraColors.lightTextPrimary,
            )
        },
        navigationIcon = {
            if (onDismiss != null) {
                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = AuroraColors.lightTextPrimary,
                    )
                }
            }
        },
        actions = {
            Box {
                IconButton(onClick = { showMonthMenu = true }) {
                    Icon(
                        imageVector = Icons.Default.CalendarMonth,
                        contentDescription = "Select month",
                        tint = AuroraColors.lightTextPrimary,
                    )
                }
                DropdownMenu(
                    expanded = showMonthMenu,
                    onDismissRequest = { showMonthMenu = false },
                ) {
                    availableMonths.forEach { window ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    text = window.displayLabel(),
                                    color = if (window == selectedMonth) AuroraColors.ember else AuroraColors.lightTextPrimary,
                                )
                            },
                            onClick = {
                                showMonthMenu = false
                                onSelectMonth(window)
                            },
                        )
                    }
                }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = AuroraColors.lightBackground,
        ),
    )
}

@Composable
private fun RecapLoadingContent() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxSize(),
    ) {
        CircularProgressIndicator(
            color = AuroraColors.amber,
            modifier = Modifier.size(40.dp),
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Reading your month…",
            style = RecapTheme.Typography.caption,
            color = AuroraColors.lightTextSecondary,
        )
    }
}

@Composable
private fun RecapNotEnoughDataContent(window: RecapWindow, onRetry: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(64.dp)
                .clip(CircleShape)
                .background(AuroraColors.amber.copy(alpha = 0.16f)),
        ) {
            Icon(
                imageVector = Icons.Default.DateRange,
                contentDescription = null,
                tint = AuroraColors.amber,
                modifier = Modifier.size(32.dp),
            )
        }
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Not enough activity yet",
            style = RecapTheme.Typography.heroHeadline.copy(fontSize = 22.sp),
            color = AuroraColors.lightTextPrimary,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "Recap builds automatically as you use AI tools throughout ${window.displayLabel()}.",
            style = RecapTheme.Typography.cardBody,
            color = AuroraColors.lightTextSecondary,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(24.dp))
        Button(onClick = onRetry) {
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Spacer(modifier = Modifier.size(8.dp))
            Text(text = "Check Again")
        }
    }
}

@Composable
private fun RecapFailedContent(message: String, onRetry: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
    ) {
        Text(
            text = "Could not build recap",
            style = RecapTheme.Typography.cardHeadline,
            color = AuroraColors.lightTextPrimary,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = message,
            style = RecapTheme.Typography.cardBody,
            color = AuroraColors.lightTextMuted,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(16.dp))
        Button(onClick = onRetry) {
            Text(text = "Retry")
        }
    }
}

@Composable
private fun RecapReadyContent(recap: MonthlyRecap, context: Context) {
    fun shareRecap(r: MonthlyRecap) {
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, r.title)
            putExtra(Intent.EXTRA_TEXT, "${r.title}\n\n${r.closingSentence}\n\nGenerated with BurnBar")
        }
        context.startActivity(Intent.createChooser(shareIntent, "Share Monthly Recap"))
    }

    fun shareCard(c: RecapCard) {
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, c.headline)
            putExtra(Intent.EXTRA_TEXT, "${c.headline}\n${c.body}\n\nGenerated with BurnBar")
        }
        context.startActivity(Intent.createChooser(shareIntent, "Share Card"))
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        RecapDeckView(
            recap = recap,
            onShareCard = { card -> shareCard(card) },
            onShareRecap = { shareRecap(recap) },
        )
        Spacer(modifier = Modifier.height(32.dp))
    }
}
