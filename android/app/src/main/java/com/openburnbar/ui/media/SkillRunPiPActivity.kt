// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.lifecycleScope
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraTheme
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
        observeJob =
            lifecycleScope.launch {
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
        val builder =
            PictureInPictureParams.Builder()
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
