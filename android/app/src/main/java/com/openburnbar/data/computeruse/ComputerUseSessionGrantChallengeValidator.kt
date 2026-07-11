package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.irohrelay.HermesRealtimeRelayComputerUseSessionGrantChallenge

object ComputerUseSessionGrantChallengeValidator {
    const val VERSION = 1
    const val MAXIMUM_LIFETIME_SECONDS = 5 * 60
    const val MAXIMUM_CLOCK_SKEW_SECONDS = 30

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

    fun validate(challenge: HermesRealtimeRelayComputerUseSessionGrantChallenge, nowMillis: Long = System.currentTimeMillis()): String {
        if (challenge.version != VERSION) throw ValidationError.UnsupportedVersion(challenge.version)
        if (!isBoundedIdentifier(challenge.challengeId)) throw ValidationError.MalformedIdentifier("challengeId")
        if (challenge.nonce.length !in 16..128 || !challenge.nonce.all { it.code <= 0x7f && !it.isWhitespace() }) {
            throw ValidationError.MalformedNonce
        }
        if (!challenge.issuedAt.isFinite() || !challenge.expiresAt.isFinite() || challenge.expiresAt <= challenge.issuedAt) {
            throw ValidationError.MalformedSession
        }
        val now = AgentCapabilityGrantRequest.swiftReferenceSeconds(nowMillis)
        if (challenge.expiresAt <= now) throw ValidationError.Expired
        if (challenge.issuedAt - now > MAXIMUM_CLOCK_SKEW_SECONDS) throw ValidationError.IssuedInFuture
        if (challenge.expiresAt - challenge.issuedAt > MAXIMUM_LIFETIME_SECONDS) throw ValidationError.LifetimeExceeded
        if (AssistantRuntimeID.values().none { it.token == challenge.runtime }) {
            throw ValidationError.UnsupportedRuntime(challenge.runtime)
        }
        val preset = AgentPermissionPreset.entries.firstOrNull { it.wireValue == challenge.preset }
            ?: throw ValidationError.UnsupportedPreset(challenge.preset)
        val capabilities = challenge.capabilities.map { raw ->
            AgentDesktopCapability.entries.firstOrNull { it.wireValue == raw }
                ?: throw ValidationError.UnsupportedCapability(raw)
        }.toSet()
        if (challenge.mode !in setOf("agent_watch", "browser", "system")) {
            throw ValidationError.UnsupportedMode(challenge.mode)
        }
        if (challenge.trustMode !in setOf("manual", "step", "trusted")) {
            throw ValidationError.UnsupportedTrustMode(challenge.trustMode)
        }
        challenge.desktopOwnerAuthorizationMethod?.let {
            if (it != "linux_desktop_owner") throw ValidationError.UnsupportedDesktopOwnerAuthorizationMethod(it)
        }
        if (challenge.trustMode == "trusted" && challenge.desktopOwnerAuthorizationMethod != "linux_desktop_owner") {
            throw ValidationError.DesktopOwnerAuthorizationRequired
        }
        if (
            preset == AgentPermissionPreset.OFF ||
            capabilities.isEmpty() ||
            !preset.capabilities.containsAll(capabilities) ||
            challenge.capabilities.size != capabilities.size
        ) {
            throw ValidationError.PresetCapabilityTrustMismatch
        }
        if (
            !isBoundedIdentifier(challenge.threadId) ||
            !isBoundedIdentifier(challenge.clientId) ||
            challenge.actionCap !in 1..10_000 ||
            challenge.sessionTimeoutSeconds !in 1..(24 * 60 * 60) ||
            challenge.scopeRuleIds.size > 256 ||
            !challenge.scopeRuleIds.all(::isBoundedIdentifier) ||
            challenge.phoneViewerNodeId?.let(::isBoundedIdentifier) == false ||
            challenge.macHostNodeId?.let(::isBoundedIdentifier) == false ||
            challenge.runId?.let(::isBoundedIdentifier) == false ||
            challenge.runCallId?.let(::isBoundedIdentifier) == false
        ) {
            throw ValidationError.MalformedSession
        }
        val expected = PhoneControlSigner.canonicalComputerUseSessionIntentId(challenge)
        if (challenge.sessionIntentId != expected) throw ValidationError.SessionIntentMismatch
        return expected
    }

    private fun isBoundedIdentifier(value: String): Boolean =
        value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 512 && value.all { it.code <= 0x7f && it != '\n' && it != '\r' }
}
