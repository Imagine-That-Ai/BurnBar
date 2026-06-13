
package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.IrohRelayFrameCodec
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F2 extra credit — the attestation digest rides every signed authority
 * envelope when the reader produces one, and the wire stays byte-identical
 * (no `attestationHashBlake3` key at all) when it does not. The provider is
 * never enforcing: a null digest must not block a send.
 */
class PhoneControlSenderAttestationTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val digest = "ab".repeat(32)

    private fun sender(frames: MutableList<HermesRealtimeRelayFrame>, attestationDigestProvider: suspend () -> String?) = PhoneControlSender(
        uid = "uid-1",
        connectionId = "conn-1",
        peerNodeId = "android-phone-1",
        signingIdentityProvider = { PhoneControlSigningIdentity.Ed25519(privateSeed) },
        counterStore = InMemoryPhoneControlCounterStore(),
        nowMillis = { 1_700_000_000_123L },
        attestationDigestProvider = attestationDigestProvider,
        frameSink = { frames += it },
    )

    private fun enforcingSender(
        frames: MutableList<HermesRealtimeRelayFrame>,
        attestationEnforcer: suspend () -> String?,
    ) = PhoneControlSender(
        uid = "uid-1",
        connectionId = "conn-1",
        peerNodeId = "android-phone-1",
        signingIdentityProvider = { PhoneControlSigningIdentity.Ed25519(privateSeed) },
        counterStore = InMemoryPhoneControlCounterStore(),
        nowMillis = { 1_700_000_000_123L },
        attestationDigestProvider = { null },
        attestationEnforcer = attestationEnforcer,
        frameSink = { frames += it },
    )

    private fun tap() = PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.5, normalizedY = 0.5)

    @Test
    fun `the digest is attached to the authority envelope when the reader has one`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val authority =
            sender(frames) { digest }.send(
                PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.5, normalizedY = 0.5),
            )

        assertEquals(digest, authority.attestationHashBlake3)
        assertEquals(digest, frames.single().control?.inputIntent?.authority?.attestationHashBlake3)
        // The signature is unaffected — the canonical intent hash never
        // covers the authority envelope.
        PhoneControlSignerVerify.verify(
            intent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                normalizedX = 0.5,
                normalizedY = 0.5,
                clientIntentId = frames.single().control?.inputIntent?.clientIntentId,
            ),
            authority = authority,
            publicKey = PhoneControlSigner.publicKey(privateSeed),
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_123L,
        )
    }

    @Test
    fun `a blank digest is treated as absent`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val authority =
            sender(frames) { "  " }.send(
                PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.5, normalizedY = 0.5),
            )
        assertNull(authority.attestationHashBlake3)
    }

    @Test
    fun `the legacy wire is byte-identical when no digest exists`() = runBlocking {
        val withDefault = mutableListOf<HermesRealtimeRelayFrame>()
        val authority =
            sender(withDefault) { null }.send(
                PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.5, normalizedY = 0.5),
            )
        assertNull(authority.attestationHashBlake3)

        val encodedJson =
            IrohRelayFrameCodec().encode(withDefault.single()).toString(Charsets.ISO_8859_1)
        assertFalse("legacy envelopes must not gain an attestation key", encodedJson.contains("attestationHashBlake3"))
        assertTrue(encodedJson.contains("signatureEd25519"))
    }

    @Test
    fun `clipboard and context-target envelopes carry the digest too`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val phoneControlSender = sender(frames) { digest }

        phoneControlSender.send(
            PhoneControlClipboardRequest(
                requestId = "req-1",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = "text/plain",
                text = "hello",
                maxBytes = 65_536,
            ),
        )
        phoneControlSender.send(
            PhoneControlAgentContextTarget(
                requestId = "req-2",
                sessionId = null,
                runtime = "hermes",
                threadId = null,
                displayId = "display-1",
                normalizedX = 0.5,
                normalizedY = 0.5,
                normalizedRect = null,
                instruction = "look here",
                focusContext = null,
                clientIntentId = "intent-2",
                requestedAt = 721_692_800.0,
            ),
        )

        assertEquals(digest, frames[0].control?.clipboardRequest?.authority?.attestationHashBlake3)
        assertEquals(digest, frames[1].control?.agentContextTarget?.authority?.attestationHashBlake3)
    }

    // RR-7c — the strict-ramp enforcer attaches an enforceable digest on the control-action path,
    // overriding the (null) best-effort provider so Android stops being attach-only.
    @Test
    fun `the enforcer attaches an enforceable digest under strict mode`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val authority = enforcingSender(frames) { digest }.send(tap())

        assertEquals(digest, authority.attestationHashBlake3)
        assertEquals(digest, frames.single().control?.inputIntent?.authority?.attestationHashBlake3)
    }

    // RR-7c — when strict mode is on and no digest can be produced, the enforcer throws and the
    // control action is NOT sent (fail-closed), mirroring iOS `SendError.attestationRequired`.
    @Test
    fun `a strict-mode send fails closed when no digest can be produced`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        assertThrows(AttestationRequiredException::class.java) {
            runBlocking { enforcingSender(frames) { throw AttestationRequiredException() }.send(tap()) }
        }
        assertTrue("no frame is emitted when attestation enforcement fails", frames.isEmpty())
    }

    // RR-7c — a null enforcer (ramp off) leaves the best-effort provider in charge: the wire is
    // byte-identical to the pre-RR-7c attach-only behavior.
    @Test
    fun `a null enforcer falls back to the best-effort provider`() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val authority = enforcingSender(frames) { null }.send(tap())
        assertNull(authority.attestationHashBlake3)
    }
}
