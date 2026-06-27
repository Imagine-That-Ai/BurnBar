package com.openburnbar.data.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Phase 2.5 G6 — cross-language byte-parity gate for the v4 Signal-envelope binding -> AAD
 * canonicalizer in TRANSPORT mode (scope=gateway, clientId/slotId-bearing). The Android mirror of
 * Swift `SignalEnvelopeTransportAADParityTests` and the Node harness section A2.
 *
 * The golden strings are the EXACT `expectedAAD` values committed in
 * `packages/signal-envelope-contracts/fixtures/transport-binding-aad-vectors.json`. Kotlin has no
 * bundled-fixture loader in this module, so they are asserted inline (mirroring
 * `CloudVaultCryptoTest.signalBindingToAadMatchesCanonicalGrammarAndRejectsInjection`). If
 * `CloudVaultCryptoSupport.bindingToAAD` drifts from the TypeScript/Swift canonicalizer by a single
 * byte, one of these assertions fails. Unicode is written with explicit escapes so the source
 * encoding cannot perturb the NFC/non-NFC bytes under test.
 */
class CloudVaultTransportBindingParityTest {
    private val full =
        SignalEnvelopeBinding(
            uid = "uid-1",
            scope = "gateway",
            clientId = "client-1",
            slotId = "event-1",
            mode = "transport",
            formatVersion = 1,
        )

    @Test
    fun transportVectorsMatchCommittedGoldenAad() {
        assertEquals(
            "OpenBurnBar-Signal-AAD-v1|transport|gateway|uid-1|client-1||||event-1|1",
            CloudVaultCryptoSupport.bindingToAAD(full),
        )
        // clientId only (slotId absent -> empty segment).
        assertEquals(
            "OpenBurnBar-Signal-AAD-v1|transport|gateway|uid-1|client-1|||||1",
            CloudVaultCryptoSupport.bindingToAAD(full.copy(slotId = null)),
        )
        // slotId only (clientId absent -> empty segment).
        assertEquals(
            "OpenBurnBar-Signal-AAD-v1|transport|gateway|uid-1|||||event-1|1",
            CloudVaultCryptoSupport.bindingToAAD(full.copy(clientId = null)),
        )
    }

    @Test
    fun transportAadSharesAtRestPipeFieldCount() {
        // The canonicalizer is mode-agnostic: a transport and an at-rest binding produce the SAME
        // pipe-field count, so the mode segment (not the field count) prevents mode confusion.
        val atRest =
            SignalEnvelopeBinding(
                uid = "u",
                scope = "cloudvault",
                collection = "col",
                docId = "d",
                field = "f",
                mode = "at-rest",
                formatVersion = 1,
            )
        val transportPipes = CloudVaultCryptoSupport.bindingToAAD(full).count { it == '|' }
        val atRestPipes = CloudVaultCryptoSupport.bindingToAAD(atRest).count { it == '|' }
        assertEquals(atRestPipes, transportPipes)
    }

    @Test
    fun nfdClientIdFailsClosedInsteadOfCollapsingToTheNfcAad() {
        // clientId "café-client": PRECOMPOSED (NFC, U+00E9) vs DECOMPOSED (NFD, e + U+0301)
        // must not canonicalize to the byte-identical AAD; the non-NFC form is rejected.
        val nfc = full.copy(clientId = "caf\u00e9-client")
        val nfd = full.copy(clientId = "cafe\u0301-client")
        assertEquals(
            "OpenBurnBar-Signal-AAD-v1|transport|gateway|uid-1|caf\u00e9-client||||event-1|1",
            CloudVaultCryptoSupport.bindingToAAD(nfc),
        )
        val error = assertThrows(IllegalArgumentException::class.java) { CloudVaultCryptoSupport.bindingToAAD(nfd) }
        assertEquals("Signal envelope binding segment must be NFC-normalized", error.message)
    }

    @Test
    fun reservedCharacterInTransportSegmentFailsClosed() {
        // `|`, CR, LF in the transport-only clientId / slotId positions must fail closed via the
        // reserved-character guard specifically (not an arbitrary error).
        val injections =
            listOf(
                full.copy(clientId = "client|evil"),
                full.copy(slotId = "slot\nevil"),
                full.copy(clientId = "client\revil"),
            )
        for (binding in injections) {
            val error = assertThrows(IllegalArgumentException::class.java) { CloudVaultCryptoSupport.bindingToAAD(binding) }
            assertEquals("Signal envelope binding segment contains a reserved character", error.message)
        }
    }
}
