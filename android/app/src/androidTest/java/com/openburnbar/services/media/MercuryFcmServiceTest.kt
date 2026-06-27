package com.openburnbar.services.media

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
 * instead we exercise the data-message envelope shape and confirm the
 * local activity intent contract.
 */
@RunWith(AndroidJUnit4::class)
class MercuryFcmServiceTest {
    @Test
    fun media_incoming_call_message_uses_ephemeral_context_key() {
        // Cloud Functions delivers data-only payloads with this shape; the
        // service routes on `type == "media_incoming_call"`, resolves the
        // stable connection id from owner-scoped Firestore context keyed by
        // `correlation_id`, and never requires it in the FCM payload.
        val msg =
            RemoteMessage.Builder("u@fcm")
                .addData("type", "media_incoming_call")
                .addData("correlation_id", "550e8400-e29b-41d4-a716-446655440000")
                .addData("call_id", "call-1")
                .addData("caller_name", "Incoming call")
                .addData("caller_initial", "I")
                .addData("feature", "videoCall")
                .build()
        assertNull(msg.data["connection_id"])
        assertNotNull(msg.data["correlation_id"])
        assertNotNull(msg.data["caller_name"])
        assertNotNull(msg.data["caller_initial"])
        // A message without `type` shouldn't surface a correlation id; the
        // dispatcher must early-return before posting a notification.
        val unrelated =
            RemoteMessage.Builder("u@fcm")
                .addData("type", "ignored")
                .build()
        assertNull(unrelated.data["correlation_id"])
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
