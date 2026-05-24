package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTheme
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Text-only Skill Run Picture-in-Picture host.
 *
 * Android PiP belongs to an Activity, so the global Skill Run tile launches
 * this small activity with a mission ID. The activity observes the same
 * Firestore mission stream as Mission Console, renders a compact live card,
 * then enters OS PiP on request/background.
 */
class SkillRunPiPActivity : ComponentActivity() {
    private val dispatcher = CLIAgentMissionDispatcher()
    private val missionState = MutableStateFlow<CLIAgentMissionSnapshot?>(null)
    private val errorState = MutableStateFlow<String?>(null)
    private var observeJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        observeMissionFromIntent()
        updatePictureInPictureParams()
        setContent {
            AuroraTheme {
                val mission by missionState.collectAsState()
                val error by errorState.collectAsState()
                SkillRunPiPScreen(
                    mission = mission,
                    error = error,
                    onEnterPiP = { enterSkillRunPictureInPicture() },
                    onClose = { finish() },
                )
            }
        }
        if (intent?.getBooleanExtra(EXTRA_ENTER_PIP, false) == true) {
            window.decorView.post { enterSkillRunPictureInPicture() }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        observeMissionFromIntent()
        updatePictureInPictureParams()
        if (intent.getBooleanExtra(EXTRA_ENTER_PIP, false)) {
            window.decorView.post { enterSkillRunPictureInPicture() }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enterSkillRunPictureInPicture()
        }
    }

    override fun onDestroy() {
        observeJob?.cancel()
        super.onDestroy()
    }

    private fun observeMissionFromIntent() {
        val missionID = intent?.getStringExtra(EXTRA_MISSION_ID)?.takeIf { it.isNotBlank() }
        if (missionID == null) {
            errorState.value = "Missing Skill Run mission."
            return
        }
        observeJob?.cancel()
        observeJob = lifecycleScope.launch {
            runCatching {
                dispatcher.observe(missionID).collect { mission ->
                    missionState.value = mission
                    errorState.value = null
                }
            }.onFailure { error ->
                errorState.value = error.localizedMessage ?: "Skill Run listener failed."
            }
        }
    }

    private fun enterSkillRunPictureInPicture(): Boolean {
        val params = buildSkillRunPictureInPictureParams() ?: return false
        return try {
            setPictureInPictureParams(params)
            enterPictureInPictureMode(params)
        } catch (_: IllegalStateException) {
            false
        }
    }

    private fun updatePictureInPictureParams() {
        val params = buildSkillRunPictureInPictureParams() ?: return
        setPictureInPictureParams(params)
    }

    private fun buildSkillRunPictureInPictureParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return null
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(true)
                .setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    companion object {
        const val EXTRA_MISSION_ID = "mission_id"
        const val EXTRA_ENTER_PIP = "enter_pip"
    }
}

@Composable
private fun SkillRunPiPScreen(
    mission: CLIAgentMissionSnapshot?,
    error: String?,
    onEnterPiP: () -> Unit,
    onClose: () -> Unit,
) {
    val accent = when {
        mission?.isWaitingForApproval == true -> AuroraColors.amber
        mission?.isTerminal == true -> AuroraColors.success
        else -> AuroraColors.ember
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    listOf(
                        MaterialTheme.colorScheme.background,
                        accent.copy(alpha = 0.18f),
                        MaterialTheme.colorScheme.surface,
                    )
                )
            )
            .padding(14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            shape = RoundedCornerShape(18.dp),
            shadowElevation = 10.dp,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier.padding(AuroraSpacing.md.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                ) {
                    Icon(
                        imageVector = missionIcon(mission, error),
                        contentDescription = null,
                        tint = accent,
                    )
                    Text(
                        text = mission?.skillRunID?.displayLabel ?: "Hermes Skill Run",
                        style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = onEnterPiP) {
                        Icon(
                            imageVector = Icons.Filled.PictureInPictureAlt,
                            contentDescription = "Enter Picture in Picture",
                            tint = AuroraColors.amber,
                        )
                    }
                    IconButton(onClick = onClose) {
                        Icon(
                            imageVector = Icons.Filled.Close,
                            contentDescription = "Close",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                Text(
                    text = mission?.title ?: error ?: "Waiting for Skill Run...",
                    style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = error
                        ?: mission?.events?.lastOrNull()?.fullMessage
                        ?: mission?.events?.lastOrNull()?.message
                        ?: mission?.displayLiveSummary
                        ?: mission?.currentStepLabel
                        ?: "Opening live timeline.",
                    style = AuroraType.caption,
                    color = if (error == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                    SkillRunPiPPill(mission?.displayStatus?.uppercase() ?: "LISTENING", accent)
                    mission?.deliveryMode?.displayLabel?.let { SkillRunPiPPill(it, AuroraColors.whimsy) }
                }
            }
        }
    }
}

private fun missionIcon(mission: CLIAgentMissionSnapshot?, error: String?) = when {
    error != null -> Icons.Filled.WarningAmber
    mission?.isWaitingForApproval == true -> Icons.Filled.WarningAmber
    mission?.isTerminal == true -> Icons.Filled.CheckCircle
    else -> Icons.Filled.AutoAwesome
}

@Composable
private fun SkillRunPiPPill(text: String, color: Color) {
    Text(
        text = text,
        style = AuroraType.tiny.copy(fontWeight = FontWeight.Bold),
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(9.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}
