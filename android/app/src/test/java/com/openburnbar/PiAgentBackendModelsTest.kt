package com.openburnbar

import com.openburnbar.data.hermes.PiAgentRuntimeModelOption
import com.openburnbar.data.hermes.PiConnectionMode
import com.openburnbar.data.hermes.PiConnectionRecord
import com.openburnbar.data.hermes.PiConnectionStatus
import com.openburnbar.data.hermes.PiService
import com.openburnbar.data.hermes.RuntimeConnectionPreferenceKind
import com.openburnbar.data.hermes.RuntimeConnectionPreferenceRecord
import com.openburnbar.data.models.DeviceLinkCapability
import com.openburnbar.data.models.DeviceLinkStatus
import com.openburnbar.data.models.ProviderAccountDeviceLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PiAgentBackendModelsTest {
    @Test
    fun `pi connection mirrors functions document tokens`() {
        val record = PiConnectionRecord(
            id = "pi-relay-mac",
            displayName = "Studio Mac Pi Relay",
            mode = PiConnectionMode.RELAY_LINK.token,
            status = PiConnectionStatus.ONLINE.token,
            selectedInstanceId = "default",
            capabilities = listOf("chat_completions", "models", "remote_relay"),
            models = listOf(
                PiAgentRuntimeModelOption(
                    id = "pi:gpt-oss",
                    providerId = "pi",
                    providerName = "Pi",
                    modelId = "gpt-oss",
                    displayName = "gpt-oss",
                    instanceId = "default"
                )
            ),
            schemaVersion = 2
        )

        assertEquals(PiConnectionMode.RELAY_LINK, record.resolvedMode)
        assertEquals(PiConnectionStatus.ONLINE, record.resolvedStatus)
        assertEquals("default", record.selectedInstanceId)
        assertEquals("gpt-oss", record.models.single().modelId)
    }

    @Test
    fun `runtime preference keeps pi separate from hermes on the same device`() {
        val hermes = RuntimeConnectionPreferenceRecord(
            id = "device-1_hermes",
            deviceId = "device-1",
            runtimeKind = RuntimeConnectionPreferenceKind.HERMES.token,
            selectedConnectionId = "hermes-mac"
        )
        val pi = RuntimeConnectionPreferenceRecord(
            id = "device-1_piAgent",
            deviceId = "device-1",
            runtimeKind = RuntimeConnectionPreferenceKind.PI_AGENT.token,
            selectedConnectionId = "pi-relay-mac",
            selectedInstanceId = "default",
            selectedModelId = "pi:gpt-oss"
        )

        assertEquals(RuntimeConnectionPreferenceKind.HERMES, hermes.resolvedRuntimeKind)
        assertEquals(RuntimeConnectionPreferenceKind.PI_AGENT, pi.resolvedRuntimeKind)
        assertFalse(hermes.id == pi.id)
        assertEquals("pi:gpt-oss", pi.selectedModelId)
    }

    @Test
    fun `provider device links group active accounts by account id`() {
        val links = listOf(
            ProviderAccountDeviceLink(
                id = "acct-a_phone",
                accountId = "acct-a",
                deviceId = "phone",
                capability = DeviceLinkCapability.USE.token,
                status = DeviceLinkStatus.ACTIVE.token
            ),
            ProviderAccountDeviceLink(
                id = "acct-a_mac",
                accountId = "acct-a",
                deviceId = "mac",
                capability = DeviceLinkCapability.OWNER.token,
                status = DeviceLinkStatus.ACTIVE.token
            ),
            ProviderAccountDeviceLink(
                id = "acct-b_tablet",
                accountId = "acct-b",
                deviceId = "tablet",
                status = DeviceLinkStatus.REVOKED.token
            )
        )

        val activeByAccount = links
            .filter { it.resolvedStatus == DeviceLinkStatus.ACTIVE }
            .groupBy { it.accountId }

        assertEquals(2, activeByAccount.getValue("acct-a").size)
        assertTrue(activeByAccount["acct-b"].isNullOrEmpty())
    }

    @Test
    fun `pi service starts on local default without fake cloud state`() {
        val service = PiService()

        assertEquals(PiConnectionRecord.localDefault.id, service.selectedConnection.value.id)
        assertEquals(PiConnectionMode.LOCAL, service.selectedConnection.value.resolvedMode)
        assertTrue(service.messages.value.isEmpty())
        assertFalse(service.isStreaming.value)
    }
}
