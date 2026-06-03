@file:Suppress("MagicNumber")

package com.openburnbar.data.missions

import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.CloudVaultSealedTextCodec
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Round-trip + privacy-posture tests for the sealed `rollback_requests` and
 * `cli_sessions/{id}/snapshots` private text (file paths, scope, diagnostics,
 * action labels). Mirrors `BudgetRuleSealedFieldsTest`:
 *  - a sealed `sealedScope` / `sealedErrorMessage` / `sealedActionLabel` /
 *    `sealedTouchedFiles` / `sealedMacSnapshotPath` envelope decodes back with the
 *    vault key and never leaks plaintext into the stored map;
 *  - legacy plaintext docs (no sealed field) still decode (migration fallback);
 *  - without a key, sealed fields stay opaque while legacy plaintext still decodes.
 *
 * The Android `CloudVaultCrypto` uses `android.util.Base64`, stubbed to JDK Base64
 * — the same idiom as `BudgetRuleSealedFieldsTest` / `HermesRelayCryptoTest`.
 */
class RollbackServiceSealedFieldsTest {
    private val vaultKey = ByteArray(32) { 0x5A.toByte() }

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    // ── rollback_requests ──

    @Test
    fun sealedRollbackRequestPayloadWritesNoPlaintextScopeJson() {
        val request =
            RollbackRequest(
                id = "req-write",
                sessionID = "session-write",
                scope = RollbackScope.SingleFile("/Users/me/secret/file.swift"),
                requestedAtEpoch = 1_700_000_000_000,
                requestedBy = "android",
                status = RollbackRequest.Status.PENDING,
                resolvedAtEpoch = null,
                errorMessage = null,
            )

        val payload = sealedRollbackRequestPayload(request, source = "android-hermes-square", vaultKey = vaultKey)

        assertTrue(payload.containsKey("sealedScope"))
        assertFalse(payload.containsKey("scopeJSON"))
        assertFalse(payload.values.any { it == request.scope.asJson || it == "/Users/me/secret/file.swift" })
    }

    @Test
    fun toRollbackRequestOpensSealedScopeAndErrorMessage() {
        val scopeJson = RollbackScope.SingleFile("/Users/me/secret/file.swift").asJson
        val data: Map<String, Any?> =
            mapOf(
                "sessionID" to "session-1",
                "sealedScope" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(scopeJson, vaultKey)),
                "sealedErrorMessage" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("boom at /Users/me/x", vaultKey)),
                "status" to "failed",
                "requestedBy" to "me",
            )

        val request = data.toRollbackRequestOrNull(documentID = "req-1", vaultKey = vaultKey)
        requireNotNull(request)
        assertEquals("session-1", request.sessionID)
        assertEquals(RollbackScope.SingleFile("/Users/me/secret/file.swift"), request.scope)
        assertEquals("boom at /Users/me/x", request.errorMessage)
        // The private path / diagnostic never appeared verbatim in the stored doc.
        assertFalse(data.values.any { it == scopeJson || it == "boom at /Users/me/x" })
    }

    @Test
    fun toRollbackRequestFallsBackToLegacyPlaintextScope() {
        val data: Map<String, Any?> =
            mapOf(
                "sessionID" to "session-2",
                "scopeJSON" to RollbackScope.LastN(3).asJson,
                "errorMessage" to "legacy error",
                "status" to "pending",
                "requestedBy" to "me",
            )

        val request = data.toRollbackRequestOrNull(documentID = "req-2", vaultKey = vaultKey)
        requireNotNull(request)
        assertEquals(RollbackScope.LastN(3), request.scope)
        assertEquals("legacy error", request.errorMessage)
    }

    @Test
    fun toRollbackRequestWithoutKeyDropsSealedOnlyRequest() {
        val sealedOnly: Map<String, Any?> =
            mapOf(
                "sessionID" to "session-3",
                "sealedScope" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("{\"kind\":\"fullSession\"}", vaultKey)),
                "scopeJSON" to RollbackScope.LastN(9).asJson,
                "status" to "pending",
            )
        // No key: sealed scope cannot open. Because the sealed field is present,
        // the legacy sibling must NOT leak.
        assertNull(sealedOnly.toRollbackRequestOrNull(documentID = "req-3", vaultKey = null))
    }

    @Test
    fun toRollbackRequestLegacyPlaintextStillDecodesWithoutKey() {
        val legacy: Map<String, Any?> =
            mapOf(
                "sessionID" to "session-legacy",
                "scopeJSON" to RollbackScope.LastN(2).asJson,
                "status" to "pending",
            )
        val request = legacy.toRollbackRequestOrNull(documentID = "req-legacy", vaultKey = null)
        requireNotNull(request)
        assertEquals(RollbackScope.LastN(2), request.scope)
    }

    @Test
    fun toRollbackRequestToleratesLegacyInFlightStatusAndRejectsUnknownStatus() {
        val base: Map<String, Any?> =
            mapOf(
                "sessionID" to "session-status",
                "scopeJSON" to RollbackScope.FullSession.asJson,
            )
        val legacy = (base + ("status" to "inFlight")).toRollbackRequestOrNull(documentID = "req-status", vaultKey = null)
        requireNotNull(legacy)
        assertEquals(RollbackRequest.Status.IN_FLIGHT, legacy.status)
        assertNull((base + ("status" to "wat")).toRollbackRequestOrNull(documentID = "req-bad-status", vaultKey = null))
    }

    // ── cli_sessions/{id}/snapshots ──

    @Test
    fun toRollbackSnapshotOpensSealedActionTouchedFilesAndPath() {
        val touchedJson = "[\"src/a.swift\",\"src/b.swift\"]"
        val data: Map<String, Any?> =
            mapOf(
                "sequence" to 2,
                "takenAt" to "2026-06-02T10:00:00Z",
                "sealedActionLabel" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Edit src/a.swift", vaultKey)),
                "sealedTouchedFiles" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(touchedJson, vaultKey)),
                "sealedMacSnapshotPath" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("/var/snap/123", vaultKey)),
            )

        val snapshot = data.toRollbackSnapshotOrNull(documentID = "snap-1", sessionID = "session-1", vaultKey = vaultKey)
        requireNotNull(snapshot)
        assertEquals("Edit src/a.swift", snapshot.actionLabel)
        assertEquals(listOf("src/a.swift", "src/b.swift"), snapshot.touchedFiles)
        assertEquals("/var/snap/123", snapshot.macSnapshotPath)
        // No private string leaked verbatim into the stored doc.
        assertFalse(data.values.any { it == "Edit src/a.swift" || it == "/var/snap/123" || it == touchedJson })
    }

    @Test
    fun toRollbackSnapshotFallsBackToLegacyPlaintext() {
        val data: Map<String, Any?> =
            mapOf(
                "sequence" to 1,
                "takenAt" to "2026-06-02T10:00:00Z",
                "actionLabel" to "Run npm test",
                "touchedFiles" to listOf("legacy/path.kt"),
                "macSnapshotPath" to "/legacy/snap",
            )

        val snapshot = data.toRollbackSnapshotOrNull(documentID = "snap-legacy", sessionID = "session-1", vaultKey = vaultKey)
        requireNotNull(snapshot)
        assertEquals("Run npm test", snapshot.actionLabel)
        assertEquals(listOf("legacy/path.kt"), snapshot.touchedFiles)
        assertEquals("/legacy/snap", snapshot.macSnapshotPath)
    }

    @Test
    fun toRollbackSnapshotWithoutKeyDropsSealedOnlyDoc() {
        // Sealed action label, no legacy plaintext, no key → actionLabel cannot be
        // resolved so the snapshot is dropped (null) rather than leaking anything.
        val data: Map<String, Any?> =
            mapOf(
                "sequence" to 1,
                "takenAt" to "2026-06-02T10:00:00Z",
                "sealedActionLabel" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Hidden", vaultKey)),
                "actionLabel" to "Legacy leak",
                "touchedFiles" to listOf("legacy/leak.kt"),
                "macSnapshotPath" to "/legacy/leak",
            )
        assertNull(data.toRollbackSnapshotOrNull(documentID = "snap-x", sessionID = "session-1", vaultKey = null))
    }

    @Test
    fun sealedScopeRoundTripsThroughCodec() {
        val scopeJson = RollbackScope.SingleFile("/Users/me/a b/c.swift").asJson
        val map = CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(scopeJson, vaultKey))
        assertEquals("AES-256-GCM", map["algorithm"])
        assertTrue(map.containsKey("nonce") && map.containsKey("ciphertext") && map.containsKey("tag"))
        assertEquals(scopeJson, CloudVaultSealedTextCodec.open(map, vaultKey))
        // Wrong key → null (no plaintext escapes).
        assertNull(CloudVaultSealedTextCodec.open(map, ByteArray(32) { 0x01.toByte() }))
    }
}
