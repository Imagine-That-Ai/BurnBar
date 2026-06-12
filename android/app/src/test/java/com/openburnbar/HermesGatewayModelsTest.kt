package com.openburnbar

import com.openburnbar.data.models.generated.FirestoreHermesGatewayAttachmentManifestDoc
import com.openburnbar.data.models.generated.FirestoreHermesGatewayClientDoc
import com.openburnbar.data.models.generated.FirestoreHermesGatewayModelOptionDoc
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesGatewayModelsTest {
    @Test
    fun `client doc exposes proof of possession signal and runtime fields`() {
        val option =
            FirestoreHermesGatewayModelOptionDoc(
                providerId = "anthropic",
                providerName = "Anthropic",
                modelId = "claude-sonnet",
                displayName = "Claude Sonnet",
            )
        val doc =
            FirestoreHermesGatewayClientDoc(
                id = "client-1",
                uid = "uid-1",
                agentClientSigningPublicKeyBase64 = "agent-public-key",
                agentClientSigningKeyId = "agent-key-id",
                popRequired = true,
                popVersion = 2,
                scopes = listOf("relay"),
                homeDestinationId = "home",
                expiresAt = "2026-06-12T15:00:00Z",
                rotatedAt = "2026-06-12T16:00:00Z",
                agentSupportsSignalEnvelope = true,
                phoneSupportsSignalEnvelope = false,
                supportsSignalEnvelope = true,
                runtimeModelId = "claude-sonnet",
                runtimeProviderId = "anthropic",
                runtimeModelOptions = listOf(option),
                runtimeUpdatedAt = "2026-06-12T17:00:00Z",
                agentVersion = "1.0.0",
                pendingModelId = "claude-opus",
                pendingModelRequestedAt = "2026-06-12T18:00:00Z",
                oversightMode = "manual",
            )

        assertEquals("agent-public-key", doc.agentClientSigningPublicKeyBase64)
        assertEquals("agent-key-id", doc.agentClientSigningKeyId)
        assertTrue(doc.popRequired == true)
        assertEquals(2L, doc.popVersion)
        assertEquals("2026-06-12T15:00:00Z", doc.expiresAt)
        assertEquals("2026-06-12T16:00:00Z", doc.rotatedAt)
        assertTrue(doc.agentSupportsSignalEnvelope == true)
        assertFalse(doc.phoneSupportsSignalEnvelope == true)
        assertTrue(doc.supportsSignalEnvelope == true)
        assertEquals("claude-sonnet", doc.runtimeModelId)
        assertEquals("anthropic", doc.runtimeProviderId)
        assertEquals(listOf(option), doc.runtimeModelOptions)
        assertEquals("2026-06-12T17:00:00Z", doc.runtimeUpdatedAt)
        assertEquals("1.0.0", doc.agentVersion)
        assertEquals("claude-opus", doc.pendingModelId)
        assertEquals("2026-06-12T18:00:00Z", doc.pendingModelRequestedAt)
        assertEquals("manual", doc.oversightMode)
    }

    @Test
    fun `attachment manifest defaults and finalized storage fields match schema`() {
        val defaults = FirestoreHermesGatewayAttachmentManifestDoc()
        assertEquals("", defaults.contentType)
        assertEquals(0L, defaults.byteCount)
        assertEquals("", defaults.storagePath)
        assertEquals("", defaults.status)
        assertNull(defaults.updatedAt)
        assertNull(defaults.uploadedAt)
        assertNull(defaults.finalizedAt)
        assertNull(defaults.sha256)
        assertNull(defaults.storageGeneration)

        val uploaded =
            FirestoreHermesGatewayAttachmentManifestDoc(
                id = "attachment-1",
                clientId = "client-1",
                contentType = "image/png",
                byteCount = 4096,
                storagePath = "users/u/attachments/a",
                status = "finalized",
                updatedAt = "2026-06-12T19:00:00Z",
                uploadedAt = "2026-06-12T19:01:00Z",
                finalizedAt = "2026-06-12T19:02:00Z",
                sha256 = "abc123",
                storageGeneration = "42",
            )

        assertEquals("image/png", uploaded.contentType)
        assertEquals(4096L, uploaded.byteCount)
        assertEquals("users/u/attachments/a", uploaded.storagePath)
        assertEquals("finalized", uploaded.status)
        assertEquals("2026-06-12T19:00:00Z", uploaded.updatedAt)
        assertEquals("2026-06-12T19:01:00Z", uploaded.uploadedAt)
        assertEquals("2026-06-12T19:02:00Z", uploaded.finalizedAt)
        assertEquals("abc123", uploaded.sha256)
        assertEquals("42", uploaded.storageGeneration)
    }
}
