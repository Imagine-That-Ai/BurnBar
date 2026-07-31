package com.openburnbar.data.cloud

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MercuryDeviceRegistrationPreflightTest {
    @Test
    fun `registration completes before ready state is published`() = runTest {
        val states = mutableListOf<MercuryDeviceRegistrationState>()
        val preflight =
            MercuryDeviceRegistrationPreflight {
                AndroidEscrowDeviceRegistration(
                    deviceId = "android-current",
                    trustState = AndroidEscrowDeviceRegistry.TRUSTED,
                )
            }

        val result = preflight.run(uid = "user-1", onState = states::add)

        assertEquals("android-current", result.deviceId)
        assertEquals(
            listOf(
                MercuryDeviceRegistrationState.Registering,
                MercuryDeviceRegistrationState.Ready("android-current"),
            ),
            states,
        )
    }

    @Test
    fun `pending registration exposes Mac approval copy`() = runTest {
        val states = mutableListOf<MercuryDeviceRegistrationState>()
        val preflight =
            MercuryDeviceRegistrationPreflight {
                AndroidEscrowDeviceRegistration(
                    deviceId = "android-new",
                    trustState = AndroidEscrowDeviceRegistry.PENDING,
                )
            }

        preflight.run(uid = "user-1", onState = states::add)

        assertEquals(
            "Approve this Android on your Mac to enable typing and trusted controls.",
            states.last().userMessage(),
        )
    }

    @Test
    fun `registration failure is surfaced and propagated instead of swallowed`() = runTest {
        val states = mutableListOf<MercuryDeviceRegistrationState>()
        val preflight =
            MercuryDeviceRegistrationPreflight {
                error("callable rejected registration")
            }

        var thrown: Throwable? = null
        try {
            preflight.run(uid = "user-1", onState = states::add)
        } catch (error: Throwable) {
            thrown = error
        }

        assertTrue(thrown is IllegalStateException)
        assertEquals("callable rejected registration", thrown?.message)
        assertEquals(
            MercuryDeviceRegistrationState.Failed("callable rejected registration"),
            states.last(),
        )
    }
}
