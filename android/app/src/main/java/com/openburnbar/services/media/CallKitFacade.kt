package com.openburnbar.services.media

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.ConnectionService
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/**
 * Android equivalent of iOS CallKit. Wraps `TelecomManager` /
 * `ConnectionService` so a Mercury call shows up in the system call
 * screen, integrates with the device speakerphone / mute, and is
 * suspended if the user receives a cellular call mid-Mercury.
 *
 * Decision 1 parity:
 *   • App foregrounded → in-app `MercuryIncomingSheet` overlay
 *     (broadcast from `IncomingCallActivity`).
 *   • App backgrounded / locked → `IncomingCallActivity` opened via
 *     full-screen-intent from `MercuryFcmService`.
 *
 * `register` is idempotent and lazy — first call performs the
 * `registerPhoneAccount`; subsequent calls reuse the handle.
 */
class CallKitFacade(private val context: Context) {

    fun register(): PhoneAccountHandle? {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return null
        val handle = phoneAccountHandle(context)
        val existing = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            telecom.getPhoneAccount(handle)
        } else {
            null
        }
        if (existing != null) return handle

        val account = PhoneAccount.builder(handle, "OpenBurnBar Mercury")
            .setShortDescription("Mac → Android Mercury calls")
            .setCapabilities(
                PhoneAccount.CAPABILITY_SELF_MANAGED or PhoneAccount.CAPABILITY_VIDEO_CALLING
            )
            .build()
        runCatching { telecom.registerPhoneAccount(account) }
        return handle
    }

    fun addIncomingCall(connectionId: String) {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        val handle = register() ?: return
        val extras = Bundle().apply {
            putString(CONNECTION_ID_KEY, connectionId)
        }
        runCatching { telecom.addNewIncomingCall(handle, extras) }
    }

    @Suppress("unused")
    fun cancelIncomingCall(connectionId: String) {
        // Hand-off to the broadcast-driven decline path so the
        // foreground service stays the single owner of call lifecycle.
        val intent = android.content.Intent(IncomingCallActivity.ACTION_BROADCAST_DECLINE).apply {
            setPackage(context.packageName)
            putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
        }
        context.sendBroadcast(intent)
    }

    companion object {
        const val CONNECTION_ID_KEY = "mercury_connection_id"

        private fun phoneAccountHandle(context: Context): PhoneAccountHandle = PhoneAccountHandle(
            ComponentName(context, MercuryConnectionService::class.java),
            "openburnbar-mercury",
        )
    }
}

/**
 * `ConnectionService` shim. We never produce real cellular connections
 * here — `Connection.STATE_RINGING` is left to the in-app sheet — but
 * the class must exist for the `PhoneAccount` registration to succeed
 * when callers ask `TelecomManager` for the self-managed pathway.
 */
class MercuryConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: android.telecom.ConnectionRequest?,
    ): android.telecom.Connection {
        return object : android.telecom.Connection() {
            override fun onAnswer() {
                setActive()
            }

            override fun onDisconnect() {
                setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
                destroy()
            }
        }.apply {
            setVideoState(android.telecom.VideoProfile.STATE_BIDIRECTIONAL)
            setAudioModeIsVoip(true)
            setRinging()
        }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: android.telecom.ConnectionRequest?,
    ): android.telecom.Connection {
        return object : android.telecom.Connection() {}.apply { setActive() }
    }

    @Suppress("unused")
    private val placeholderAddress: Uri = Uri.parse("mercury://burnbar")
}
