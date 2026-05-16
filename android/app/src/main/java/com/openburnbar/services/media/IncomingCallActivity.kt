package com.openburnbar.services.media

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.openburnbar.ui.media.MercuryIncomingSheet

/**
 * Full-screen Mercury incoming-call sheet. Android equivalent of the
 * iOS `MercuryIncomingSheet` rendered as a `View` instead of a `Window`
 * because we need lock-screen / turn-screen-on semantics.
 *
 * Launched from:
 *   • `MercuryFcmService` via `FullScreenIntent` (background dispatch
 *     path mirrors iOS Decision 1 — Mac → APNs → PushKit → CallKit).
 *   • A foreground BurnBar instance via `Intent` (in-app dispatch path).
 *
 * The activity itself does not own the call — it dispatches accept /
 * decline back to BurnBar and exits. The active call lives in
 * `MediaSessionForegroundService` + `CallSessionCoordinator`.
 */
class IncomingCallActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableLockScreenSemantics()

        val connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID).orEmpty()
        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty().ifEmpty { "OpenBurnBar" }
        val callerInitial = intent.getStringExtra(EXTRA_CALLER_INITIAL).orEmpty().ifEmpty {
            callerName.firstOrNull()?.toString() ?: "M"
        }

        when (intent.action) {
            ACTION_ACCEPT -> {
                acceptCall(connectionId)
                finish()
                return
            }
            ACTION_DECLINE -> {
                declineCall(connectionId)
                finish()
                return
            }
        }

        setContent {
            MercuryIncomingSheet(
                pairedDeviceName = callerName,
                callerInitial = callerInitial,
                onAccept = {
                    acceptCall(connectionId)
                    finish()
                },
                onDecline = {
                    declineCall(connectionId)
                    finish()
                },
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun enableLockScreenSemantics() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguard?.requestDismissKeyguard(this, null)
        } else {
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    android.view.WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
    }

    private fun acceptCall(connectionId: String) {
        MediaSessionForegroundService.start(this)
        val accept = Intent(ACTION_BROADCAST_ACCEPT).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONNECTION_ID, connectionId)
        }
        sendBroadcast(accept)
    }

    private fun declineCall(connectionId: String) {
        val decline = Intent(ACTION_BROADCAST_DECLINE).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONNECTION_ID, connectionId)
        }
        sendBroadcast(decline)
    }

    companion object {
        const val ACTION_ACCEPT = "com.openburnbar.media.ACCEPT"
        const val ACTION_DECLINE = "com.openburnbar.media.DECLINE"
        const val ACTION_BROADCAST_ACCEPT = "com.openburnbar.media.broadcast.CALL_ACCEPTED"
        const val ACTION_BROADCAST_DECLINE = "com.openburnbar.media.broadcast.CALL_DECLINED"
        const val EXTRA_CONNECTION_ID = "connection_id"
        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_CALLER_INITIAL = "caller_initial"
    }
}
