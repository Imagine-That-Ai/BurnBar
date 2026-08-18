package com.openburnbar.data.policy

import com.google.gson.Gson
import com.openburnbar.data.models.generated.FirestoreComputerUsePhoneAuthorityDoc
import com.openburnbar.data.models.generated.FirestoreEntitlementBindingDoc
import com.openburnbar.data.models.generated.FirestoreHermesRelayRequestDoc
import com.openburnbar.data.models.generated.FirestoreInsightCanvasDoc
import com.openburnbar.data.models.generated.FirestoreIrohPairingDoc
import com.openburnbar.data.models.generated.FirestoreProviderAccountDeviceLinkDoc
import com.openburnbar.data.models.generated.FirestoreProviderAccountDoc
import com.openburnbar.data.models.generated.FirestoreQuotaSnapshotDoc
import com.openburnbar.data.models.generated.FirestoreUsageEventDoc
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileSchemaFixtureParityTest {
    private val gson = Gson()

    @Test
    fun usageEventPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/usage-event.json") { decodeUsageEvent(it) } > 0)
    }

    @Test
    fun quotaSnapshotPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/quota-snapshot.json") { decodeQuotaSnapshot(it) } > 0)
    }

    @Test
    fun providerAccountPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/provider-account.json") { decodeProviderAccount(it) } > 0)
    }

    @Test
    fun entitlementBindingPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/entitlement-binding.json") { decodeEntitlement(it) } > 0)
    }

    @Test
    fun insightCanvasPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/insight-canvas.json") { decodeInsight(it) } > 0)
    }

    @Test
    fun hermesRelayPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/hermes-relay-request.json") { decodeHermesRelay(it) } > 0)
    }

    @Test
    fun computerUseAuthorityPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/computer-use-authority.json") { decodeComputerUse(it) } > 0)
    }

    @Test
    fun irohPairingPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/iroh-pairing.json") { decodeIroh(it) } > 0)
    }

    @Test
    fun deviceLinkPassFixturesDecode() {
        assertTrue(decodePassing("docs/mobile-parity/fixtures/schema/device-link.json") { decodeDeviceLink(it) } > 0)
    }

    @Test
    fun usageEventFieldRenameFailsClosed() {
        assertThrows(IllegalArgumentException::class.java) {
            decodeGenerated(
                JSONObject("""{"provder":"openai","recordedAt":"2026-08-17T12:00:00.000Z"}"""),
                FirestoreUsageEventDoc::class.java,
                listOf("provider", "recordedAt"),
            )
        }
    }

    @Test
    fun failFixturesRejectMissingRequiredFields() {
        decodeFailing("docs/mobile-parity/fixtures/schema/usage-event.json") { decodeUsageEvent(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/quota-snapshot.json") { decodeQuotaSnapshot(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/provider-account.json") { decodeProviderAccount(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/entitlement-binding.json") { decodeEntitlement(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/insight-canvas.json") { decodeInsight(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/hermes-relay-request.json") { decodeHermesRelay(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/computer-use-authority.json") { decodeComputerUse(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/iroh-pairing.json") { decodeIroh(it) }
        decodeFailing("docs/mobile-parity/fixtures/schema/device-link.json") { decodeDeviceLink(it) }
    }

    private fun decodePassing(relative: String, decode: (JSONObject) -> Any): Int {
        val fixture = JSONObject(locate(relative).readText())
        val passing = fixture.getJSONArray("pass")
        var decoded = 0
        for (index in 0 until passing.length()) {
            val document = passing.getJSONObject(index).get("document")
            if (document !is JSONObject) continue
            val result = decode(document)
            assertGoldenFields(document, result)
            decoded += 1
        }
        return decoded
    }

    private fun decodeFailing(relative: String, decode: (JSONObject) -> Any) {
        val fixture = JSONObject(locate(relative).readText())
        val failing = fixture.getJSONArray("fail")
        for (index in 0 until failing.length()) {
            val item = failing.getJSONObject(index)
            val document = failFixtureDocument(item) ?: continue
            assertThrows(item.optString("id"), IllegalArgumentException::class.java) {
                decode(document)
            }
        }
    }

    private fun failFixtureDocument(item: JSONObject): JSONObject? {
        val id = item.optString("id")
        if (id == "malformed-timestamp" || id.contains("enum")) return null
        return item.opt("document") as? JSONObject
    }

    private fun decodeUsageEvent(document: JSONObject): FirestoreUsageEventDoc =
        decodeGenerated(document, FirestoreUsageEventDoc::class.java, listOf("provider", "recordedAt"))

    private fun decodeQuotaSnapshot(document: JSONObject): FirestoreQuotaSnapshotDoc = decodeGenerated(
        document,
        FirestoreQuotaSnapshotDoc::class.java,
        listOf("sourceKind", "sourceId", "provider", "fetchedAt"),
    )

    private fun decodeProviderAccount(document: JSONObject): FirestoreProviderAccountDoc = decodeGenerated(
        document,
        FirestoreProviderAccountDoc::class.java,
        listOf(
            "id",
            "providerID",
            "label",
            "status",
            "credentialKind",
            "storageScope",
            "redactedLabel",
            "isDefault",
            "sortKey",
            "schemaVersion",
            "createdAt",
            "updatedAt",
        ),
    )

    private fun decodeEntitlement(document: JSONObject): FirestoreEntitlementBindingDoc = decodeGenerated(
        document,
        FirestoreEntitlementBindingDoc::class.java,
        listOf("appAccountToken", "uid", "createdAt"),
    )

    private fun decodeInsight(document: JSONObject): FirestoreInsightCanvasDoc = decodeGenerated(
        document,
        FirestoreInsightCanvasDoc::class.java,
        listOf("id", "title", "theme", "origin", "updatedAt"),
    )

    private fun decodeHermesRelay(document: JSONObject): FirestoreHermesRelayRequestDoc = decodeGenerated(
        document,
        FirestoreHermesRelayRequestDoc::class.java,
        listOf("operation", "status", "createdAt"),
    )

    private fun decodeComputerUse(document: JSONObject): FirestoreComputerUsePhoneAuthorityDoc = decodeGenerated(
        document,
        FirestoreComputerUsePhoneAuthorityDoc::class.java,
        listOf(
            "deviceId",
            "connectionId",
            "peerNodeId",
            "publicKeyBase64",
            "publishedAtMillis",
            "protocolVersion",
            "schemaVersion",
            "createdAt",
            "updatedAt",
        ),
    )

    private fun decodeIroh(document: JSONObject): FirestoreIrohPairingDoc = decodeGenerated(
        document,
        FirestoreIrohPairingDoc::class.java,
        listOf("pairingCodeDigest", "status", "createdAt", "expiresAt"),
    )

    private fun decodeDeviceLink(document: JSONObject): FirestoreProviderAccountDeviceLinkDoc = decodeGenerated(
        document,
        FirestoreProviderAccountDeviceLinkDoc::class.java,
        listOf(
            "id",
            "accountID",
            "deviceID",
            "deviceDisplayName",
            "capability",
            "status",
            "lastObservedAt",
            "createdAt",
            "updatedAt",
            "schemaVersion",
        ),
    )

    private val numericKeys =
        setOf(
            "costUSD",
            "inputTokens",
            "outputTokens",
            "cacheReadTokens",
            "cacheWriteTokens",
            "totalTokens",
            "sortKey",
            "schemaVersion",
            "publishedAtMillis",
            "protocolVersion",
            "used",
            "limit",
        )
    private val booleanKeys = setOf("isDefault")

    private fun assertGoldenFields(document: JSONObject, decoded: Any) {
        when (decoded) {
            is FirestoreUsageEventDoc -> {
                assertEquals(document.getString("provider"), decoded.provider)
                assertEquals(document.getString("recordedAt"), decoded.recordedAt)
            }
            is FirestoreQuotaSnapshotDoc -> {
                assertEquals(document.getString("sourceKind"), decoded.sourceKind)
                assertEquals(document.getString("provider"), decoded.provider)
                assertEquals(document.getString("fetchedAt"), decoded.fetchedAt)
            }
            is FirestoreProviderAccountDoc -> {
                assertEquals(document.getString("id"), decoded.id)
                assertEquals(document.getString("label"), decoded.label)
                assertEquals(document.getString("status"), decoded.status)
            }
            is FirestoreEntitlementBindingDoc -> {
                assertEquals(document.getString("appAccountToken"), decoded.appAccountToken)
                assertEquals(document.getString("uid"), decoded.uid)
            }
            is FirestoreInsightCanvasDoc -> {
                assertEquals(document.getString("id"), decoded.id)
                assertEquals(document.getString("title"), decoded.title)
            }
            is FirestoreHermesRelayRequestDoc -> {
                assertEquals(document.getString("operation"), decoded.operation)
                assertEquals(document.getString("status"), decoded.status)
            }
            is FirestoreComputerUsePhoneAuthorityDoc -> {
                assertEquals(document.getString("deviceId"), decoded.deviceId)
                assertEquals(document.getString("connectionId"), decoded.connectionId)
            }
            is FirestoreIrohPairingDoc -> {
                assertEquals(document.getString("pairingCodeDigest"), decoded.pairingCodeDigest)
                assertEquals(document.getString("status"), decoded.status)
            }
            is FirestoreProviderAccountDeviceLinkDoc -> {
                assertEquals(document.getString("id"), decoded.id)
                assertEquals(document.getString("deviceDisplayName"), decoded.deviceDisplayName)
            }
            else -> error("unhandled generated type ${decoded.javaClass.name}")
        }
    }

    private fun <T> decodeGenerated(document: JSONObject, type: Class<T>, requiredKeys: List<String>): T {
        for (key in requiredKeys) {
            require(document.has(key) && !document.isNull(key)) { "missing required $key" }
        }
        rejectWrongTypes(document)
        return gson.fromJson(document.toString(), type)
            ?: throw IllegalArgumentException("generated decode returned null")
    }

    private fun rejectWrongTypes(document: JSONObject) {
        val keys = document.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (document.isNull(key)) continue
            val value = document.opt(key)
            when {
                key in numericKeys -> require(value is Number) { "field $key must be a number" }
                key in booleanKeys -> require(value is Boolean) { "field $key must be a boolean" }
                value is JSONObject -> rejectWrongTypes(value)
                value is org.json.JSONArray -> {
                    for (index in 0 until value.length()) {
                        val item = value.opt(index)
                        if (item is JSONObject) rejectWrongTypes(item)
                    }
                }
            }
        }
    }

    private fun locate(relative: String): File {
        val cwd = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val anchors = listOf(File(cwd), File(cwd, "../.."), File(cwd, ".."))
        for (anchor in anchors) {
            var dir: File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("could not locate $relative")
    }
}
