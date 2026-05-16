package com.openburnbar.services.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented coverage for `IncomingCallActivity`. We dispatch the
 * ACCEPT action via an explicit Intent and verify the activity
 * broadcasts `ACTION_BROADCAST_ACCEPT` with the same `connection_id`
 * before finishing — the contract `MediaSessionForegroundService`
 * relies on.
 */
@RunWith(AndroidJUnit4::class)
class IncomingCallActivityTest {

    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun accept_intent_broadcasts_accepted_with_connection_id() {
        val latch = CountDownLatch(1)
        var capturedConnectionId: String? = null
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                capturedConnectionId = intent.getStringExtra(IncomingCallActivity.EXTRA_CONNECTION_ID)
                latch.countDown()
            }
        }
        val filter = IntentFilter(IncomingCallActivity.ACTION_BROADCAST_ACCEPT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        try {
            val intent = Intent(context, IncomingCallActivity::class.java).apply {
                action = IncomingCallActivity.ACTION_ACCEPT
                putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, "conn-xyz")
                putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, "Albert")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ActivityScenario.launch<IncomingCallActivity>(intent).use {
                assertTrue(
                    "expected ACCEPT broadcast within 3s",
                    latch.await(3, TimeUnit.SECONDS),
                )
                assertEquals("conn-xyz", capturedConnectionId)
            }
        } finally {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
            }
        }
    }
}
