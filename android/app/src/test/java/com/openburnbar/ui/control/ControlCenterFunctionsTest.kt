package com.openburnbar.ui.control

import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class ControlCenterFunctionsTest {
    private val securityClient = mockk<ComputerUseSecurityCallableClient>()
    private val functions =
        ControlCenterFunctions(
            functions = mockk<FirebaseFunctions>(relaxed = true),
            securityClient = securityClient,
        )

    @Before
    fun stubDeviceKeypair() {
        val keypair = mockk<AndroidCloudVaultDeviceKeypair>()
        every { keypair.deviceId } returns "android-test-device"
        mockkObject(AndroidCloudVaultDeviceKeypair.Companion)
        every { AndroidCloudVaultDeviceKeypair.loadOrCreate() } returns keypair
    }

    @After
    fun tearDown() {
        unmockkAll()
    }

    @Test
    fun deleteDomainDataRoutesThroughHighRiskOwnerAction() {
        coEvery {
            securityClient.callHighRiskOwnerAction(
                callableName = any(),
                deviceId = any(),
                actionKind = any(),
                subjectId = any(),
                payload = any(),
                approve = any(),
            )
        } returns mapOf("ok" to true, "domainId" to "dom-1")

        val result = runBlocking { functions.deleteDomainData("dom-1") }

        assertEquals(mapOf("ok" to true, "domainId" to "dom-1"), result)
        coVerify(exactly = 1) {
            securityClient.callHighRiskOwnerAction(
                callableName = "deleteDomainData",
                deviceId = "android-test-device",
                actionKind = "data_domain_delete",
                subjectId = "dom-1",
                payload = mapOf("domainId" to "dom-1", "confirm" to true),
                approve = true,
            )
        }
    }

    @Test
    fun deleteDomainDataFallsBackToEmptyMapForNonStringKeys() {
        coEvery {
            securityClient.callHighRiskOwnerAction(
                callableName = any(),
                deviceId = any(),
                actionKind = any(),
                subjectId = any(),
                payload = any(),
                approve = any(),
            )
        } returns mapOf(1 to "not-a-string-key")

        val result = runBlocking { functions.deleteDomainData("dom-2") }

        assertEquals(emptyMap<String, Any>(), result)
    }
}
