@file:Suppress("MagicNumber")

package com.openburnbar.data.square

import com.openburnbar.data.cloud.CloudVaultCrypto
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Android `@Serializable` mirror of the Swift `CLIAgentSessionRecord`
 * against the exact JSON the Mac writer seals (ISO-8601 dates, Swift property
 * names). A drift here means sealed `cli_sessions` render blank on Android after
 * the Mac switches to sealed writes.
 *
 * Source of truth:
 *   `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift`.
 */
class CLIAgentSealedSessionPayloadTest {
    private val swiftCanonicalJson =
        """
        {
          "agent": "codex",
          "createdAt": "2026-06-02T12:00:00Z",
          "customTitle": "My refactor",
          "encryptedTranscriptAvailable": false,
          "id": "session-1",
          "isPinned": true,
          "labelColorHex": "#3366FF",
          "messages": [
            {
              "id": "m1",
              "isError": false,
              "role": "user",
              "text": "fix the parser",
              "timestamp": "2026-06-02T12:00:01Z",
              "toolUses": []
            },
            {
              "id": "m2",
              "isError": false,
              "role": "assistant",
              "text": "done",
              "timestamp": "2026-06-02T12:00:05Z",
              "toolUses": [
                {
                  "id": "t1",
                  "name": "edit_file",
                  "startedAt": "2026-06-02T12:00:03Z",
                  "status": "done",
                  "detail": "ThreadInboxStore.kt"
                }
              ]
            }
          ],
          "modelName": "gpt-5-codex",
          "preview": "fix the parser",
          "priorityOrder": 4,
          "resumeHandle": {
            "canFork": false,
            "canForward": true,
            "canResume": true,
            "providerSessionID": "codex-abc"
          },
          "schemaVersion": 1,
          "sourceKind": "live_chat",
          "title": "Refactor session",
          "tokenUsage": {
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "inputTokens": 100,
            "outputTokens": 42,
            "reasoningTokens": 7
          },
          "updatedAt": "2026-06-02T12:00:05Z",
          "workspaceLabel": "BurnBar"
        }
        """.trimIndent()

    @Test
    fun decodesSwiftCanonicalRecordJson() {
        val payload =
            cliAgentSealedSessionJson.decodeFromString(
                CLIAgentSealedSessionPayload.serializer(),
                swiftCanonicalJson,
            )

        assertEquals("session-1", payload.id)
        assertEquals("codex", payload.agent)
        assertEquals("live_chat", payload.sourceKind)
        assertEquals("Refactor session", payload.title)
        assertEquals("My refactor", payload.customTitle)
        assertEquals("BurnBar", payload.workspaceLabel)
        assertEquals("gpt-5-codex", payload.modelName)
        assertEquals(true, payload.isPinned)
        assertEquals("#3366FF", payload.labelColorHex)
        assertEquals(4, payload.priorityOrder)
        assertEquals(2, payload.messages.size)
        assertEquals("user", payload.messages[0].role)
        assertEquals("ThreadInboxStore.kt", payload.messages[1].toolUses.single().detail)
        assertEquals("codex-abc", payload.resumeHandle?.providerSessionID)
        assertTrue(payload.resumeHandle?.canResume == true)
        assertEquals(42, payload.tokenUsage?.outputTokens)
    }

    @Test
    fun toleratesUnknownFutureFields() {
        val withExtra =
            """
            { "id": "s2", "agent": "claude", "title": "t", "preview": "p",
              "schemaVersion": 1, "futureField": "ignored", "newNested": { "x": 1 } }
            """.trimIndent()
        val payload =
            cliAgentSealedSessionJson.decodeFromString(
                CLIAgentSealedSessionPayload.serializer(),
                withExtra,
            )
        assertEquals("s2", payload.id)
        assertEquals("claude", payload.agent)
        assertNull(payload.customTitle)
    }

    @Test
    fun sealedPayloadRoundTripsThroughVaultCrypto() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
        try {
            val key = ByteArray(32) { 0x11.toByte() }
            val original =
                cliAgentSealedSessionJson.decodeFromString(
                    CLIAgentSealedSessionPayload.serializer(),
                    swiftCanonicalJson,
                )

            val sealed =
                CloudVaultCrypto.sealPayload(
                    cliAgentSealedSessionJson.encodeToString(
                        CLIAgentSealedSessionPayload.serializer(),
                        original,
                    ).toByteArray(Charsets.UTF_8),
                    key,
                    CloudVaultCrypto.vaultKeyID(key),
                )

            val map = CloudVaultCrypto.sealedPayloadMap(sealed)
            val reopened =
                CloudVaultCrypto.sealedPayloadFromMap(map)?.let { envelope ->
                    cliAgentSealedSessionJson.decodeFromString(
                        CLIAgentSealedSessionPayload.serializer(),
                        CloudVaultCrypto.openPayload(envelope, key).toString(Charsets.UTF_8),
                    )
                }

            assertEquals(original, reopened)
            assertEquals("My refactor", reopened?.customTitle)
        } finally {
            unmockkStatic(android.util.Base64::class)
        }
    }

    @Test
    fun renameReSealsCustomTitleInsidePayload() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
        try {
            val key = ByteArray(32) { 0x22.toByte() }
            val keyID = CloudVaultCrypto.vaultKeyID(key)
            val original =
                cliAgentSealedSessionJson.decodeFromString(
                    CLIAgentSealedSessionPayload.serializer(),
                    swiftCanonicalJson,
                )

            // Simulate the rename re-seal path: mutate only customTitle, re-encode
            // the WHOLE record, re-seal.
            val renamed = original.copy(customTitle = "Renamed by phone")
            val reSealed =
                CloudVaultCrypto.sealPayload(
                    cliAgentSealedSessionJson.encodeToString(
                        CLIAgentSealedSessionPayload.serializer(),
                        renamed,
                    ).toByteArray(Charsets.UTF_8),
                    key,
                    keyID,
                )

            val opened =
                cliAgentSealedSessionJson.decodeFromString(
                    CLIAgentSealedSessionPayload.serializer(),
                    CloudVaultCrypto.openPayload(reSealed, key).toString(Charsets.UTF_8),
                )

            assertEquals("Renamed by phone", opened.customTitle)
            // Every other Mac-written field survives the rename losslessly.
            assertEquals(original.messages, opened.messages)
            assertEquals(original.tokenUsage, opened.tokenUsage)
            assertEquals(original.resumeHandle, opened.resumeHandle)
            assertEquals(original.workspaceLabel, opened.workspaceLabel)
        } finally {
            unmockkStatic(android.util.Base64::class)
        }
    }

    @After
    fun ensureUnmocked() {
        // Per-test static mocking is scoped inside each Base64-using test; this
        // guards against a leaked static mock if one of them threw mid-test.
        runCatching { unmockkStatic(android.util.Base64::class) }
    }
}
