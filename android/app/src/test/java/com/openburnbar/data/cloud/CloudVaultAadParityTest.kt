package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-language known-answer test for the Cloud Vault at-rest AAD context (RR-8).
 *
 * The golden strings are duplicated verbatim in the Swift KAT
 * `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultAADParityTests.swift`.
 * The AES-256-GCM additional-authenticated-data is exactly `CloudVaultAADContext.stringValue`
 * UTF-8 bytes, so ANY divergence between the Kotlin and Swift string causes a payload sealed
 * on one platform to silently fail to decrypt on the other (the original RR-8 cross-platform
 * data loss). Change one side and you MUST change the other.
 */
class CloudVaultAadParityTest {
    @Test
    fun assistantChatAadStringMatchesGolden() {
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "mobile_assistant_chats",
            docID = "THREAD456",
            field = "sealedPayload",
        )
        assertEquals(
            "OpenBurnBar-CloudVault-aad-v2|UID123|mobile_assistant_chats|THREAD456|sealedPayload|2|sealedPayload",
            ctx.stringValue,
        )
    }

    @Test
    fun missionRequestAadStringMatchesGolden() {
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "cli_agent_mission_requests",
            docID = "REQ789",
            field = "sealedPayload",
        )
        assertEquals(
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests|REQ789|sealedPayload|2|sealedPayload",
            ctx.stringValue,
        )
    }

    @Test
    fun missionStateAadStringMatchesGolden() {
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "cli_agent_mission_requests",
            docID = "REQ789",
            field = "sealedStatePayload",
        )
        assertEquals(
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests|REQ789|sealedStatePayload|2|sealedStatePayload",
            ctx.stringValue,
        )
    }

    @Test
    fun missionEventAadStringMatchesGolden() {
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "cli_agent_mission_requests/events",
            docID = "REQ789/EVT1",
            field = "sealedPayload",
        )
        assertEquals(
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests/events|REQ789/EVT1|sealedPayload|2|sealedPayload",
            ctx.stringValue,
        )
    }

    @Test
    fun aadBytesAreStringValueUtf8() {
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "mobile_assistant_chats",
            docID = "THREAD456",
            field = "sealedPayload",
        )
        assertArrayEquals(ctx.stringValue.toByteArray(Charsets.UTF_8), ctx.bytes)
    }

    /** Path-bound payload sealed with a context round-trips with the same context. */
    @Test
    fun pathBoundPayloadRoundTripsWithMatchingContext() {
        val key = ByteArray(32) { 0x5A.toByte() }
        val vaultKeyID = CloudVaultCrypto.vaultKeyID(key)
        val ctx = CloudVaultAADContext(
            uid = "UID123",
            collection = "mobile_assistant_chats",
            docID = "THREAD456",
            field = "sealedPayload",
        )
        val plaintext = """{"private":"chat history"}""".toByteArray(Charsets.UTF_8)
        val sealed = CloudVaultCrypto.sealPayload(plaintext, key, vaultKeyID, aadContext = ctx)
        assertEquals(ctx.stringValue, sealed.aad)
        assertArrayEquals(plaintext, CloudVaultCrypto.openPayload(sealed, key, aadContext = ctx))
        // Opening a path-bound payload WITHOUT the context must fail (not silently mis-open).
        assertTrue(runCatching { CloudVaultCrypto.openPayload(sealed, key) }.isFailure)
    }
}
