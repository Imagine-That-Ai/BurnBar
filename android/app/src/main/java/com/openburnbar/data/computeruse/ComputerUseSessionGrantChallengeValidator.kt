package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.irohrelay.HermesRealtimeRelaySessionGrantChallenge

object ComputerUseSessionGrantChallengeValidator {
    const val VERSION = 1
    const val MAXIMUM_LIFETIME_SECONDS = 5 * 60
    const val MAXIMUM_CLOCK_SKEW_SECONDS = 30
    private const val MINIMUM_NONCE_LENGTH = 16
    private const val MAXIMUM_NONCE_LENGTH = 128
    private const val MAXIMUM_IDENTIFIER_BYTES = 512
    private const val MAXIMUM_ACTION_CAP = 10_000
    private const val MAXIMUM_SESSION_TIMEOUT_SECONDS = 24 * 60 * 60
    private const val MAXIMUM_SCOPE_RULES = 256
    private const val MAXIMUM_ASCII_CODE_POINT = 127
    private val supportedModes = setOf("agent_watch", "browser", "system")
    private val supportedTrustModes = setOf("manual", "step", "trusted")

    sealed class ValidationError(message: String) : IllegalArgumentException(message) {
        data class UnsupportedVersion(val value: Int) : ValidationError("Unsupported challenge version: $value")
        data class MalformedIdentifier(val field: String) : ValidationError("Malformed challenge field: $field")
        object MalformedNonce : ValidationError("Malformed challenge nonce")
        object MalformedSession : ValidationError("Malformed session fields")
        object Expired : ValidationError("Session grant challenge expired")
        object IssuedInFuture : ValidationError("Session grant challenge was issued in the future")
        object LifetimeExceeded : ValidationError("Session grant challenge lifetime exceeds five minutes")
        data class UnsupportedRuntime(val value: String) : ValidationError("Unsupported runtime: $value")
        data class UnsupportedPreset(val value: String) : ValidationError("Unsupported preset: $value")
        data class UnsupportedCapability(val value: String) : ValidationError("Unsupported capability: $value")
        data class UnsupportedMode(val value: String) : ValidationError("Unsupported mode: $value")
        data class UnsupportedTrustMode(val value: String) : ValidationError("Unsupported trust mode: $value")
        data class UnsupportedDesktopOwnerAuthorizationMethod(val value: String) :
            ValidationError("Unsupported desktop-owner authorization method: $value")
        object DesktopOwnerAuthorizationRequired : ValidationError("Trusted mode requires Linux desktop-owner authorization")
        object PresetCapabilityTrustMismatch : ValidationError("Preset, capabilities, and trust mode do not match")
        object SessionIntentMismatch : ValidationError("Session intent identifier does not match challenge fields")
    }

    fun validate(challenge: HermesRealtimeRelaySessionGrantChallenge, nowMillis: Long = System.currentTimeMillis()): String {
        validateEnvelope(challenge)
        validateTiming(challenge, nowMillis)
        validateRuntimeAndMode(challenge)
        val preset = validatedPreset(challenge.preset)
        val capabilities = validatedCapabilities(challenge.capabilities)
        validatePresetCapabilities(preset, capabilities, challenge.capabilities.size)
        validateSessionFields(challenge)
        val expected = PhoneControlSigner.canonicalComputerUseSessionIntentId(challenge)
        if (challenge.sessionIntentId != expected) throw ValidationError.SessionIntentMismatch
        return expected
    }

    private fun validateEnvelope(challenge: HermesRealtimeRelaySessionGrantChallenge) {
        val nonceIsValid =
            challenge.nonce.length in MINIMUM_NONCE_LENGTH..MAXIMUM_NONCE_LENGTH &&
                challenge.nonce.all { it.code <= MAXIMUM_ASCII_CODE_POINT && !it.isWhitespace() }
        val envelopeError = when {
            challenge.version != VERSION -> ValidationError.UnsupportedVersion(challenge.version)
            !isBoundedIdentifier(challenge.challengeId) -> ValidationError.MalformedIdentifier("challengeId")
            !nonceIsValid -> ValidationError.MalformedNonce
            else -> null
        }
        if (envelopeError != null) throw envelopeError
    }

    private fun validateTiming(challenge: HermesRealtimeRelaySessionGrantChallenge, nowMillis: Long) {
        val hasValidBounds =
            challenge.issuedAt.isFinite() && challenge.expiresAt.isFinite() && challenge.expiresAt > challenge.issuedAt
        if (!hasValidBounds) throw ValidationError.MalformedSession
        val now = AgentCapabilityGrantRequest.swiftReferenceSeconds(nowMillis)
        val timingError = when {
            challenge.expiresAt <= now -> ValidationError.Expired
            challenge.issuedAt - now > MAXIMUM_CLOCK_SKEW_SECONDS -> ValidationError.IssuedInFuture
            challenge.expiresAt - challenge.issuedAt > MAXIMUM_LIFETIME_SECONDS -> ValidationError.LifetimeExceeded
            else -> null
        }
        if (timingError != null) throw timingError
    }

    private fun validateRuntimeAndMode(challenge: HermesRealtimeRelaySessionGrantChallenge) {
        if (AssistantRuntimeID.values().none { it.token == challenge.runtime }) {
            throw ValidationError.UnsupportedRuntime(challenge.runtime)
        }
        val modeError = when {
            challenge.mode !in supportedModes -> ValidationError.UnsupportedMode(challenge.mode)
            challenge.trustMode !in supportedTrustModes -> ValidationError.UnsupportedTrustMode(challenge.trustMode)
            challenge.desktopOwnerAuthorizationMethod?.let { it != "linux_desktop_owner" } == true ->
                ValidationError.UnsupportedDesktopOwnerAuthorizationMethod(challenge.desktopOwnerAuthorizationMethod.orEmpty())
            challenge.trustMode == "trusted" && challenge.desktopOwnerAuthorizationMethod != "linux_desktop_owner" ->
                ValidationError.DesktopOwnerAuthorizationRequired
            else -> null
        }
        if (modeError != null) throw modeError
    }

    private fun validatedPreset(raw: String): AgentPermissionPreset = AgentPermissionPreset.entries.firstOrNull { it.wireValue == raw }
        ?: throw ValidationError.UnsupportedPreset(raw)

    private fun validatedCapabilities(rawCapabilities: List<String>): Set<AgentDesktopCapability> = rawCapabilities.map { raw ->
        AgentDesktopCapability.entries.firstOrNull { it.wireValue == raw }
            ?: throw ValidationError.UnsupportedCapability(raw)
    }.toSet()

    private fun validatePresetCapabilities(preset: AgentPermissionPreset, capabilities: Set<AgentDesktopCapability>, rawCapabilityCount: Int) {
        val invalid =
            preset == AgentPermissionPreset.OFF ||
                capabilities.isEmpty() ||
                !preset.capabilities.containsAll(capabilities) ||
                rawCapabilityCount != capabilities.size
        if (invalid) throw ValidationError.PresetCapabilityTrustMismatch
    }

    private fun validateSessionFields(challenge: HermesRealtimeRelaySessionGrantChallenge) {
        val coreFieldsAreValid =
            isBoundedIdentifier(challenge.threadId) &&
                isBoundedIdentifier(challenge.clientId) &&
                challenge.actionCap in 1..MAXIMUM_ACTION_CAP &&
                challenge.sessionTimeoutSeconds in 1..MAXIMUM_SESSION_TIMEOUT_SECONDS
        val scopeFieldsAreValid =
            challenge.scopeRuleIds.size <= MAXIMUM_SCOPE_RULES &&
                challenge.scopeRuleIds.all(::isBoundedIdentifier)
        val optionalIdentifiersAreValid = listOf(
            challenge.phoneViewerNodeId,
            challenge.macHostNodeId,
            challenge.runId,
            challenge.runCallId,
        ).all { it == null || isBoundedIdentifier(it) }
        if (!coreFieldsAreValid || !scopeFieldsAreValid || !optionalIdentifiersAreValid) {
            throw ValidationError.MalformedSession
        }
    }

    private fun isBoundedIdentifier(value: String): Boolean = value.isNotEmpty() &&
        value.toByteArray(Charsets.UTF_8).size <= MAXIMUM_IDENTIFIER_BYTES &&
        value.all { it.code <= MAXIMUM_ASCII_CODE_POINT && it != '\n' && it != '\r' }
}
