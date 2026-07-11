package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayComputerUseSessionGrantChallenge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ComputerUseSessionGrantChallengeValidatorTest {
    private val goldenHash = "3d6398b75451a30ff531b969d3b73568d0baeb09ed9010b0d7aa134316aae6f5"

    @Test
    fun sessionIntentMatchesCrossPlatformGoldenVector() {
        val challenge = challenge()

        assertEquals(
            "{" +
                "\"actionCap\":50," +
                "\"clientId\":\"linux-desktop\"," +
                "\"desktopOwnerAuthorizationMethod\":\"linux_desktop_owner\"," +
                "\"macHostNodeId\":\"linux-host-1\"," +
                "\"mode\":\"browser\"," +
                "\"phoneViewerNodeId\":\"phone-viewer-1\"," +
                "\"runCallId\":\"call-7\"," +
                "\"runGeneration\":4," +
                "\"runId\":\"run-42\"," +
                "\"scopeRuleIds\":[\"deny-payments\",\"workspace-only\"]," +
                "\"sessionTimeoutSeconds\":1800," +
                "\"trustMode\":\"manual\"," +
                "\"version\":2" +
                "}",
            PhoneControlSignerCanonicalJson.canonicalComputerUseSessionIntentJson(challenge),
        )
        assertEquals(goldenHash, PhoneControlSigner.canonicalComputerUseSessionIntentId(challenge))
        assertEquals(goldenHash, ComputerUseSessionGrantChallengeValidator.validate(challenge, nowMillis = unixMillis(800_000_100.0)))
    }

    @Test
    fun validatedChallengeBuildsExactExistingGrantRequest() {
        val request = AgentCapabilityGrantRequest.fromValidatedSessionChallenge(
            challenge = challenge(),
            sourceDeviceId = "android-device-1",
            localAuthenticationSatisfied = true,
            nowMillis = unixMillis(800_000_100.0),
        )

        assertEquals("challenge-00000001", request.requestId)
        assertEquals(goldenHash, request.clientIntentId)
        assertEquals("codex", request.runtime)
        assertEquals(AgentPermissionPreset.DESKTOP, request.preset)
        assertEquals(AgentGrantDeliveryMode.LIVE, request.deliveryMode)
        assertEquals(1_800.0, request.grantDurationSeconds, 0.0)
        assertEquals(true, request.localAuthenticationSatisfied)
    }

    @Test
    fun desktopSubsetWithStepTrustBuildsExactGrant() {
        val unsigned = challenge().copy(
            capabilities = listOf("desktop_browser", "desktop_screenshot"),
            trustMode = "step",
        )
        val exact = unsigned.copy(
            sessionIntentId = PhoneControlSigner.canonicalComputerUseSessionIntentId(unsigned),
        )

        val request = AgentCapabilityGrantRequest.fromValidatedSessionChallenge(
            challenge = exact,
            sourceDeviceId = "android-device-1",
            nowMillis = unixMillis(800_000_100.0),
        )

        assertEquals(setOf(AgentDesktopCapability.DESKTOP_BROWSER, AgentDesktopCapability.DESKTOP_SCREENSHOT), request.capabilities)
        assertEquals("step", request.trustMode)
        assertEquals(exact.sessionIntentId, request.clientIntentId)
    }

    @Test
    fun capabilityOutsidePresetIsRejectedEvenWhenIntentHashMatches() {
        val unsigned = challenge().copy(
            capabilities = challenge().capabilities + AgentDesktopCapability.SHELL_UNRESTRICTED.wireValue,
        )
        val exact = unsigned.copy(
            sessionIntentId = PhoneControlSigner.canonicalComputerUseSessionIntentId(unsigned),
        )

        assertThrows(ComputerUseSessionGrantChallengeValidator.ValidationError.PresetCapabilityTrustMismatch::class.java) {
            ComputerUseSessionGrantChallengeValidator.validate(
                exact,
                nowMillis = unixMillis(800_000_100.0),
            )
        }
    }

    @Test
    fun challengeFailsClosedOnExpiryMismatchAndTrustElevation() {
        assertThrows(ComputerUseSessionGrantChallengeValidator.ValidationError.Expired::class.java) {
            ComputerUseSessionGrantChallengeValidator.validate(challenge(), nowMillis = unixMillis(800_000_301.0))
        }
        assertThrows(ComputerUseSessionGrantChallengeValidator.ValidationError.SessionIntentMismatch::class.java) {
            ComputerUseSessionGrantChallengeValidator.validate(
                challenge().copy(actionCap = 51),
                nowMillis = unixMillis(800_000_100.0),
            )
        }
        assertThrows(ComputerUseSessionGrantChallengeValidator.ValidationError.SessionIntentMismatch::class.java) {
            ComputerUseSessionGrantChallengeValidator.validate(
                challenge().copy(
                    trustMode = "trusted",
                ),
                nowMillis = unixMillis(800_000_100.0),
            )
        }
        assertThrows(ComputerUseSessionGrantChallengeValidator.ValidationError.DesktopOwnerAuthorizationRequired::class.java) {
            ComputerUseSessionGrantChallengeValidator.validate(
                challenge().copy(
                    preset = AgentPermissionPreset.YOLO.wireValue,
                    capabilities = AgentPermissionPreset.YOLO.capabilities.map { it.wireValue },
                    trustMode = "trusted",
                    desktopOwnerAuthorizationMethod = null,
                ),
                nowMillis = unixMillis(800_000_100.0),
            )
        }
    }

    @Test
    fun desktopOwnerRequirementChangesCanonicalIntent() {
        val withRequirement = PhoneControlSigner.canonicalComputerUseSessionIntentId(challenge())
        val withoutRequirement = PhoneControlSigner.canonicalComputerUseSessionIntentId(
            challenge().copy(desktopOwnerAuthorizationMethod = null),
        )
        assertNotEquals(withRequirement, withoutRequirement)
    }

    private fun challenge() = HermesRealtimeRelayComputerUseSessionGrantChallenge(
        version = 1,
        challengeId = "challenge-00000001",
        nonce = "0123456789abcdef0123456789abcdef",
        issuedAt = 800_000_000.0,
        expiresAt = 800_000_300.0,
        sessionIntentId = goldenHash,
        runtime = "codex",
        threadId = "thread-linux-1",
        preset = AgentPermissionPreset.DESKTOP.wireValue,
        capabilities = AgentPermissionPreset.DESKTOP.capabilities.map { it.wireValue },
        mode = "browser",
        trustMode = "manual",
        scopeRuleIds = listOf("workspace-only", "deny-payments"),
        phoneViewerNodeId = "phone-viewer-1",
        macHostNodeId = "linux-host-1",
        actionCap = 50,
        sessionTimeoutSeconds = 1_800,
        clientId = "linux-desktop",
        runId = "run-42",
        runCallId = "call-7",
        runGeneration = 4,
        desktopOwnerAuthorizationMethod = "linux_desktop_owner",
    )

    private fun unixMillis(swiftReferenceSeconds: Double): Long = AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(swiftReferenceSeconds)
}
