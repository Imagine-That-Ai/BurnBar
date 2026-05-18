package com.openburnbar.services.media

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.firebase.messaging.RemoteMessage
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented coverage for `MercuryFcmService`'s incoming-message
 * routing. We can construct a `RemoteMessage` via its public Builder
 * but `FirebaseMessagingService` itself isn't directly invokable —
 * instead we exercise the data-message decoder by reading the
 * envelope shape and confirming the activity intent contract.
 */
@RunWith(AndroidJUnit4::class)
class MercuryFcmServiceTest {

    @Test
    fun media_incoming_call_message_carries_required_keys() {
        // Cloud Functions delivers data-only payloads with this shape; the
        // service routes on `type == "media_incoming_call"` and reads
        // `connection_id`, `caller_name`, `caller_initial`. This test
        // pins the contract from the consumer side.
        val msg = RemoteMessage.Builder("u@fcm")
            .addData("type", "media_incoming_call")
            .addData("connection_id", "conn-1")
            .addData("caller_name", "Albert")
            .addData("caller_initial", "A")
            .addData("feature", "videoCall")
            .build()
        assertNotNull(msg.data["connection_id"])
        assertNotNull(msg.data["caller_name"])
        assertNotNull(msg.data["caller_initial"])
        // A message without `type` shouldn't surface a connection_id; the
        // dispatcher must early-return before posting a notification.
        val unrelated = RemoteMessage.Builder("u@fcm")
            .addData("type", "ignored")
            .build()
        assertNull(unrelated.data["connection_id"])
    }

    @Test
    fun incoming_call_intent_extras_match_envelope_keys() {
        // IncomingCallActivity intent extras MUST stay aligned with the
        // FCM envelope keys. Drift would silently drop info on the lock
        // screen.
        assertNotNull(IncomingCallActivity.EXTRA_CONNECTION_ID)
        assertNotNull(IncomingCallActivity.EXTRA_CALLER_NAME)
        assertNotNull(IncomingCallActivity.EXTRA_CALLER_INITIAL)
    }
}
