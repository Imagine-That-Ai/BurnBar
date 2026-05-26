package com.openburnbar.irohrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class HermesRealtimeRelayControlFrameTest {
    @Test
    fun codecRoundTripsControlInputIntentFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
            uid = "uid-1",
            connectionId = "conn-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.input",
                inputIntent = HermesRealtimeRelayInputIntent(
                    kind = HermesRealtimeRelayInputIntentKind.POINTER_CLICK,
                    displayId = "display-1",
                    mouseButton = 1,
                    clientIntentId = "intent-1",
                    authority = HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId = "android-phone-1",
                        counter = 42,
                        timestamp = 721_692_800.123,
                        intentHashBlake3 = "f".repeat(64),
                        signatureEd25519 = "signature",
                    ),
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, decoded.type)
        assertEquals("control.input", decoded.control?.streamClass)
        assertNotNull(decoded.control?.inputIntent)
        assertEquals(HermesRealtimeRelayInputIntentKind.POINTER_CLICK, decoded.control?.inputIntent?.kind)
        assertEquals("display-1", decoded.control?.inputIntent?.displayId)
        assertEquals(1, decoded.control?.inputIntent?.mouseButton)
        assertEquals("intent-1", decoded.control?.inputIntent?.clientIntentId)
        assertEquals(42L, decoded.control?.inputIntent?.authority?.counter)
        assertEquals("f".repeat(64), decoded.control?.inputIntent?.authority?.intentHashBlake3)
    }

    @Test
    fun codecRoundTripsControlDeniedFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_DENIED,
            uid = "uid-1",
            connectionId = "conn-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.input",
                sessionId = "session-1",
                denied = HermesRealtimeRelayControlDenied(
                    reason = HermesRealtimeRelayControlDenied.Reason.UNKNOWN,
                    detail = "accessibility_revoked",
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_DENIED, decoded.type)
        assertEquals("control.input", decoded.control?.streamClass)
        assertEquals("session-1", decoded.control?.sessionId)
        assertEquals(HermesRealtimeRelayControlDenied.Reason.UNKNOWN, decoded.control?.denied?.reason)
        assertEquals("accessibility_revoked", decoded.control?.denied?.detail)
    }

    @Test
    fun codecRoundTripsRemoteUnlockCredentialAndResultFrames() {
        val authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "android-phone-1",
            counter = 43,
            timestamp = 721_692_800.123,
            intentHashBlake3 = "a".repeat(64),
            signatureEd25519 = "signature",
        )
        val credentialFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REMOTE_UNLOCK_CREDENTIAL,
            uid = "uid-unlock",
            connectionId = "conn-unlock",
            requestId = "credential-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "remote_unlock",
                sessionId = "unlock-session-1",
                remoteUnlockCredential = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
                    requestId = "credential-1",
                    sessionId = "unlock-session-1",
                    clientIntentId = "client-credential-1",
                    credentialKind = HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.CLIPBOARD_PASSWORD,
                    recipientKeyId = "mac-remote-unlock-key",
                    algorithm = "HPKE-X25519-SHA256-CHACHAPOLY",
                    ciphertextBase64 = "Y2lwaGVydGV4dA==",
                    aadBase64 = "YWFk",
                    redactedByteCount = 16,
                    requestedAt = "2026-03-22T10:26:42.000Z",
                    expiresAt = "2026-03-22T10:27:12.000Z",
                    authority = authority,
                ),
            ),
        )
        val stateFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REMOTE_UNLOCK_STATE,
            uid = "uid-unlock",
            connectionId = "conn-unlock",
            requestId = "unlock-session-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "remote_unlock",
                sessionId = "unlock-session-1",
                remoteUnlockState = HermesRealtimeRelayRemoteUnlockState(
                    sessionId = "unlock-session-1",
                    lockState = HermesRealtimeRelayMacLockState.LOGIN_WINDOW,
                    backend = HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK,
                    capabilities = HermesRealtimeRelayRemoteUnlockCapabilities(
                        enabled = true,
                        certificationStatus = HermesRealtimeRelayRemoteUnlockCertificationStatus.CERTIFIED,
                        certifiedAt = "2026-03-22T10:26:40.000Z",
                        certifiedOSBuild = "23G93",
                        activeBackend = HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK,
                        supportedBackends = listOf(HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK),
                        supportedLockStates = listOf(HermesRealtimeRelayMacLockState.LOGIN_WINDOW),
                        allowsCredentialPaste = true,
                        credentialRecipientKeyId = "mac-remote-unlock-key",
                        credentialRecipientPublicKeyBase64 = "cHVibGljLWtleQ==",
                        credentialEnvelopeAlgorithm = "HPKE-X25519-SHA256-CHACHAPOLY",
                    ),
                    controlOwnerViewerId = "viewer-1",
                    observedAt = "2026-03-22T10:26:41.000Z",
                ),
            ),
        )
        val resultFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REMOTE_UNLOCK_RESULT,
            uid = "uid-unlock",
            connectionId = "conn-unlock",
            requestId = "credential-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "remote_unlock",
                sessionId = "unlock-session-1",
                remoteUnlockResult = HermesRealtimeRelayRemoteUnlockResult(
                    requestId = "credential-1",
                    sessionId = "unlock-session-1",
                    status = HermesRealtimeRelayRemoteUnlockResult.Status.UNLOCKED,
                    lockState = HermesRealtimeRelayMacLockState.UNLOCKED,
                    backend = HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK,
                    detail = "unlocked",
                    completedAt = "2026-03-22T10:26:50.000Z",
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decodedCredential = codec.decode(codec.encode(credentialFrame)).frame
        val decodedState = codec.decode(codec.encode(stateFrame)).frame
        val decodedResult = codec.decode(codec.encode(resultFrame)).frame

        assertEquals(HermesRealtimeRelayFrameType.REMOTE_UNLOCK_CREDENTIAL, decodedCredential.type)
        assertEquals("remote_unlock", decodedCredential.control?.streamClass)
        assertEquals(
            HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.CLIPBOARD_PASSWORD,
            decodedCredential.control?.remoteUnlockCredential?.credentialKind,
        )
        assertEquals(16, decodedCredential.control?.remoteUnlockCredential?.redactedByteCount)
        assertEquals("HPKE-X25519-SHA256-CHACHAPOLY", decodedCredential.control?.remoteUnlockCredential?.algorithm)
        assertEquals(HermesRealtimeRelayFrameType.REMOTE_UNLOCK_STATE, decodedState.type)
        assertEquals(
            "mac-remote-unlock-key",
            decodedState.control?.remoteUnlockState?.capabilities?.credentialRecipientKeyId,
        )
        assertEquals(
            "HPKE-X25519-SHA256-CHACHAPOLY",
            decodedState.control?.remoteUnlockState?.capabilities?.credentialEnvelopeAlgorithm,
        )
        assertEquals(HermesRealtimeRelayFrameType.REMOTE_UNLOCK_RESULT, decodedResult.type)
        assertEquals(HermesRealtimeRelayRemoteUnlockResult.Status.UNLOCKED, decodedResult.control?.remoteUnlockResult?.status)
        assertEquals(HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK, decodedResult.control?.remoteUnlockResult?.backend)
    }

    @Test
    fun codecRoundTripsControlApprovalRequestAndResponseFrames() {
        val requestFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST,
            uid = "uid-approval",
            connectionId = "conn-approval",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.approval",
                sessionId = "session-1",
                approvalRequest = HermesRealtimeRelayApprovalRequest(
                    approvalId = "approval-1",
                    runId = "run-1",
                    sessionId = "session-1",
                    toolKind = "computer_use.mac_input.scroll",
                    title = "Scroll the active window",
                    message = "Scroll the active window",
                    actionSummary = "Scroll the active window",
                    requestedAt = 801_000_000.0,
                    trustMode = "manual",
                ),
            ),
        )
        val responseFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
            uid = "uid-approval",
            connectionId = "conn-approval",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.approval",
                sessionId = "session-1",
                approvalResponse = HermesRealtimeRelayApprovalResponse(
                    approvalId = "approval-1",
                    decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                    respondedBy = "phone",
                    respondedAt = 801_000_001.0,
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decodedRequest = codec.decode(codec.encode(requestFrame)).frame
        val decodedResponse = codec.decode(codec.encode(responseFrame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST, decodedRequest.type)
        assertEquals("approval-1", decodedRequest.control?.approvalRequest?.approvalId)
        assertEquals("manual", decodedRequest.control?.approvalRequest?.trustMode)
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE, decodedResponse.type)
        assertEquals("approval-1", decodedResponse.control?.approvalResponse?.approvalId)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.APPROVE, decodedResponse.control?.approvalResponse?.decision)
        assertEquals("phone", decodedResponse.control?.approvalResponse?.respondedBy)
    }

    @Test
    fun codecDecodesLegacyFocusContextWithoutSmartZoomFields() {
        val legacyJson = """
            {
              "type": "media.stream.frame",
              "uid": "uid-legacy",
              "connectionId": "conn-legacy",
              "media": {
                "streamClass": "media.stream.screen.video.v1",
                "focusContext": {
                  "appName": "OldMac",
                  "bundleId": "com.old.mac",
                  "windowTitle": "Old Window",
                  "windowId": 12345
                }
              }
            }
        """.trimIndent()
        val frame = HermesRealtimeRelayJson.decodeFromString(
            HermesRealtimeRelayFrame.serializer(),
            legacyJson,
        )
        val focus = frame.media?.focusContext
        assertNotNull(focus)
        assertEquals("OldMac", focus?.appName)
        assertEquals("com.old.mac", focus?.bundleId)
        assertEquals("Old Window", focus?.windowTitle)
        assertEquals(12345L, focus?.windowId)
        // Smart Zoom fields must default to null so older payloads continue to parse.
        assertEquals(null, focus?.targetKind)
        assertEquals(null, focus?.displayId)
        assertEquals(null, focus?.normalizedRect)
        assertEquals(null, focus?.normalizedPoint)
        assertEquals(null, focus?.confidence)
        assertEquals(null, focus?.updatedAt)
    }

    @Test
    fun codecRoundTripsSmartZoomFocusContext() {
        val codec = IrohRelayFrameCodec()
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
            uid = "uid-smart",
            connectionId = "conn-smart",
            media = HermesRealtimeRelayMediaPayload(
                streamClass = "media.stream.screen.video.v1",
                focusContext = HermesRealtimeRelayFocusContext(
                    appName = "Terminal",
                    bundleId = "com.apple.terminal",
                    targetKind = HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT,
                    displayId = "display-1",
                    normalizedRect = HermesRealtimeRelayNormalizedRect(
                        x = 0.4, y = 0.45, width = 0.2, height = 0.05
                    ),
                    confidence = 0.95,
                    updatedAt = 778_000_000.123,
                ),
            ),
        )
        val decoded = codec.decode(codec.encode(frame)).frame
        val focus = decoded.media?.focusContext
        assertNotNull(focus)
        assertEquals("Terminal", focus?.appName)
        assertEquals(HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT, focus?.targetKind)
        assertEquals("display-1", focus?.displayId)
        assertEquals(0.4, focus?.normalizedRect?.x)
        assertEquals(0.2, focus?.normalizedRect?.width)
        assertEquals(0.95, focus?.confidence)
        assertEquals(778_000_000.123, focus?.updatedAt)
    }

    @Test
    fun codecRoundTripsMirrorStopFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_STOP,
            uid = "uid-1",
            connectionId = "conn-1",
            requestId = "req-stop-1",
            media = HermesRealtimeRelayMediaPayload(
                mirrorStop = HermesRealtimeRelayMirrorStop(
                    requestId = "req-stop-1",
                    sessionId = "session-1",
                    stoppedAt = 801_000_002.0,
                    reason = "viewer_closed",
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.MEDIA_MIRROR_STOP, decoded.type)
        assertEquals("req-stop-1", decoded.requestId)
        assertEquals("req-stop-1", decoded.media?.mirrorStop?.requestId)
        assertEquals("session-1", decoded.media?.mirrorStop?.sessionId)
        assertEquals(801_000_002.0, decoded.media?.mirrorStop?.stoppedAt)
        assertEquals("viewer_closed", decoded.media?.mirrorStop?.reason)
    }
}
