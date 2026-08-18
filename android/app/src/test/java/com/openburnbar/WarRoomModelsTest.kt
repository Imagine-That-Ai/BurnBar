package com.openburnbar

import com.openburnbar.data.models.generated.FirestoreHermesBodyDoc
import com.openburnbar.data.models.generated.FirestoreHermesBodyEndpoints
import com.openburnbar.data.models.generated.FirestoreHermesBodyHardware
import com.openburnbar.data.models.generated.FirestoreHermesBodyHermesState
import com.openburnbar.data.models.generated.FirestoreHermesBodyPresence
import com.openburnbar.data.models.generated.FirestoreOriginatorRef
import com.openburnbar.data.models.generated.FirestoreWarWireGrantDoc
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android consumer of the War Room documents the Mac publishes.
 *
 * A phone that reads `hermes_bodies` renders a fleet, so a silently dropped
 * field would show a Mac as offline or capability-less rather than failing
 * loudly. These pin the defaults (what a partially written document decodes
 * to) and the `@PropertyName` remaps, which are the two places Kotlin and the
 * canonical schema can drift apart without the compiler noticing.
 */
class WarRoomModelsTest {
    @Test
    fun `body defaults describe a machine that claims nothing`() {
        val defaults = FirestoreHermesBodyDoc()

        assertEquals("", defaults.id)
        assertEquals("", defaults.deviceId)
        assertEquals("", defaults.displayName)
        assertEquals("", defaults.machineName)
        assertEquals("", defaults.platform)
        assertEquals(emptyList<String>(), defaults.capabilities)
        assertEquals(0L, defaults.schemaVersion)
        assertEquals("", defaults.createdAt)
        assertEquals("", defaults.updatedAt)
        // Nested defaults matter as much as the top level: an absent `hermes`
        // map must read as "no gateway", never as a reachable one.
        assertFalse(defaults.hermes.installed)
        assertFalse(defaults.hermes.gatewayReachable)
        assertNull(defaults.hermes.version)
        assertNull(defaults.hermes.gatewayClientId)
        assertNull(defaults.hermes.botCount)
        assertNull(defaults.hermes.botsUpdatedAt)
        assertNull(defaults.hardware.hardwareModel)
        assertNull(defaults.hardware.chipBrand)
        assertNull(defaults.hardware.coresPerformance)
        assertNull(defaults.hardware.coresEfficiency)
        assertNull(defaults.hardware.memBytes)
        assertNull(defaults.hardware.gpu)
        assertNull(defaults.endpoints.irohNodeId)
        assertEquals("", defaults.endpoints.pairingConnectionId)
        assertEquals("", defaults.presence.state)
        assertEquals("", defaults.presence.lastHeartbeatAt)
        assertFalse(defaults.presence.wireReachable)
    }

    @Test
    fun `a fully published body carries hardware, gateway, endpoints and presence`() {
        val body =
            FirestoreHermesBodyDoc(
                id = "body-a",
                deviceId = "device-a",
                displayName = "Studio",
                machineName = "albertos-mac-studio",
                platform = "macOS",
                hardware =
                FirestoreHermesBodyHardware(
                    hardwareModel = "Mac15,14",
                    chipBrand = "Apple M3 Ultra",
                    coresPerformance = 16,
                    coresEfficiency = 8,
                    memBytes = 137_438_953_472,
                    gpu = "80-core GPU",
                ),
                hermes =
                FirestoreHermesBodyHermesState(
                    installed = true,
                    gatewayReachable = true,
                    version = "0.9.1",
                    gatewayClientId = "client-1",
                    botCount = 4,
                    botsUpdatedAt = "2026-08-18T19:00:00Z",
                ),
                endpoints =
                FirestoreHermesBodyEndpoints(
                    irohNodeId = "node-1",
                    pairingConnectionId = "conn-1",
                ),
                presence =
                FirestoreHermesBodyPresence(
                    state = "online",
                    lastHeartbeatAt = "2026-08-18T19:01:00Z",
                    wireReachable = true,
                ),
                capabilities = listOf("hermes_gateway", "war_wire_v1"),
                schemaVersion = 1,
                createdAt = "2026-08-18T18:00:00Z",
                updatedAt = "2026-08-18T19:01:00Z",
            )

        assertEquals("body-a", body.id)
        assertEquals("device-a", body.deviceId)
        assertEquals("Studio", body.displayName)
        assertEquals("albertos-mac-studio", body.machineName)
        assertEquals("macOS", body.platform)
        assertEquals("Apple M3 Ultra", body.hardware.chipBrand)
        assertEquals(16L, body.hardware.coresPerformance)
        assertEquals(8L, body.hardware.coresEfficiency)
        assertEquals(137_438_953_472L, body.hardware.memBytes)
        assertEquals("80-core GPU", body.hardware.gpu)
        assertEquals("Mac15,14", body.hardware.hardwareModel)
        assertTrue(body.hermes.installed)
        assertTrue(body.hermes.gatewayReachable)
        assertEquals("0.9.1", body.hermes.version)
        assertEquals("client-1", body.hermes.gatewayClientId)
        assertEquals(4L, body.hermes.botCount)
        assertEquals("2026-08-18T19:00:00Z", body.hermes.botsUpdatedAt)
        assertEquals("node-1", body.endpoints.irohNodeId)
        assertEquals("conn-1", body.endpoints.pairingConnectionId)
        assertEquals("online", body.presence.state)
        assertEquals("2026-08-18T19:01:00Z", body.presence.lastHeartbeatAt)
        assertTrue(body.presence.wireReachable)
        assertTrue(body.capabilities.contains("war_wire_v1"))
        assertEquals(1L, body.schemaVersion)
        assertEquals("2026-08-18T18:00:00Z", body.createdAt)
        assertEquals("2026-08-18T19:01:00Z", body.updatedAt)
    }

    @Test
    fun `an originator names who asked, and admits when it is unsure`() {
        val defaults = FirestoreOriginatorRef()
        assertEquals("", defaults.kind)
        assertEquals("", defaults.label)
        assertEquals("", defaults.confidence)
        assertNull(defaults.bodyId)
        assertNull(defaults.decisionId)
        assertNull(defaults.missionId)
        assertNull(defaults.missionGroupId)
        assertNull(defaults.botName)

        val attributed =
            FirestoreOriginatorRef(
                kind = "bot",
                label = "Scribe",
                bodyId = "body-a",
                decisionId = "decision-1",
                missionId = "mission-1",
                missionGroupId = "group-1",
                botName = "scribe",
                confidence = "certain",
            )
        assertEquals("bot", attributed.kind)
        assertEquals("Scribe", attributed.label)
        assertEquals("body-a", attributed.bodyId)
        assertEquals("decision-1", attributed.decisionId)
        assertEquals("mission-1", attributed.missionId)
        assertEquals("group-1", attributed.missionGroupId)
        assertEquals("scribe", attributed.botName)
        assertEquals("certain", attributed.confidence)
    }

    @Test
    fun `a wire grant records who opened the lane and who closed it`() {
        val defaults = FirestoreWarWireGrantDoc()
        assertEquals("", defaults.state)
        assertEquals("", defaults.grantedByDeviceId)
        assertNull(defaults.revokedByDeviceId)
        assertNull(defaults.revokedAt)

        val revoked =
            FirestoreWarWireGrantDoc(
                id = "body-a__body-b",
                bodyIdA = "body-a",
                bodyIdB = "body-b",
                state = "revoked",
                grantedByDeviceId = "device-a",
                grantedAt = "2026-08-18T18:30:00Z",
                revokedByDeviceId = "device-b",
                revokedAt = "2026-08-18T19:30:00Z",
                schemaVersion = 1,
                createdAt = "2026-08-18T18:30:00Z",
                updatedAt = "2026-08-18T19:30:00Z",
            )

        assertEquals("body-a__body-b", revoked.id)
        assertEquals("body-a", revoked.bodyIdA)
        assertEquals("body-b", revoked.bodyIdB)
        assertEquals("revoked", revoked.state)
        assertEquals("device-a", revoked.grantedByDeviceId)
        assertEquals("2026-08-18T18:30:00Z", revoked.grantedAt)
        assertEquals("device-b", revoked.revokedByDeviceId)
        assertEquals("2026-08-18T19:30:00Z", revoked.revokedAt)
        assertEquals(1L, revoked.schemaVersion)
        assertEquals("2026-08-18T18:30:00Z", revoked.createdAt)
        assertEquals("2026-08-18T19:30:00Z", revoked.updatedAt)
    }
}
