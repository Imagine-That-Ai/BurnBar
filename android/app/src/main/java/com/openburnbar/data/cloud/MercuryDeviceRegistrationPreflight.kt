package com.openburnbar.data.cloud

import kotlinx.coroutines.CancellationException

/**
 * Process-wide state for the Android escrow identity required by Mercury
 * pairing and phone control. Pairing may proceed while approval is pending,
 * but it must never start before registration has succeeded.
 */
sealed interface MercuryDeviceRegistrationState {
    data object Idle : MercuryDeviceRegistrationState

    data object Registering : MercuryDeviceRegistrationState

    data class PendingApproval(
        val deviceId: String,
    ) : MercuryDeviceRegistrationState

    data class Ready(
        val deviceId: String,
    ) : MercuryDeviceRegistrationState

    data class Failed(
        val message: String,
    ) : MercuryDeviceRegistrationState
}

internal class MercuryDeviceRegistrationPreflight(
    private val register: suspend (uid: String) -> AndroidEscrowDeviceRegistration,
) {
    suspend fun run(uid: String, onState: (MercuryDeviceRegistrationState) -> Unit): AndroidEscrowDeviceRegistration {
        onState(MercuryDeviceRegistrationState.Registering)
        return runCatching { register(uid) }
            .fold(
                onSuccess = { registration ->
                    onState(
                        if (registration.trustState == AndroidEscrowDeviceRegistry.TRUSTED) {
                            MercuryDeviceRegistrationState.Ready(registration.deviceId)
                        } else {
                            MercuryDeviceRegistrationState.PendingApproval(registration.deviceId)
                        },
                    )
                    registration
                },
                onFailure = { error ->
                    if (error is CancellationException) throw error
                    onState(
                        MercuryDeviceRegistrationState.Failed(
                            error.message?.takeIf { it.isNotBlank() }
                                ?: "Android device registration failed.",
                        ),
                    )
                    throw error
                },
            )
    }
}

internal fun MercuryDeviceRegistrationState.userMessage(): String? = when (this) {
    MercuryDeviceRegistrationState.Idle,
    is MercuryDeviceRegistrationState.Ready,
    -> null

    MercuryDeviceRegistrationState.Registering ->
        "Securing this Android for Mercury..."

    is MercuryDeviceRegistrationState.PendingApproval ->
        "Approve this Android on your Mac to enable typing and trusted controls."

    is MercuryDeviceRegistrationState.Failed ->
        "Android security setup failed: $message"
}
