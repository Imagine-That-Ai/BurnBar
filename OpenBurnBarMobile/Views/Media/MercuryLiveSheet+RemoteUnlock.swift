import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import LocalAuthentication
import OSLog
import Security
#if canImport(UIKit)
import UIKit
#endif

// Remote-unlock state/session/credential flow, phone-control authority, and clipboard bridge.
// Extracted from MercuryLiveSheet.swift (god-type decomposition) — same module, same isolation, verbatim.

extension MercuryLiveSheet {

    func setRemoteUnlockState(_ state: HermesRealtimeRelayRemoteUnlockState) {
        let previousBlockers = remoteUnlockState?.capabilities.blockers ?? []
        let incomingBlockers = state.capabilities.blockers
        if incomingBlockers != previousBlockers {
            // Exact blocker identifiers live in logs only — users see the
            // mapped, product-ready copy from RemoteUnlockBlockerPresentationMap.
            if incomingBlockers.isEmpty {
                Self.log.debug("Remote Unlock blockers cleared (lockState=\(state.lockState.rawValue, privacy: .public))")
            } else {
                Self.log.debug("Remote Unlock blockers: \(incomingBlockers.joined(separator: ", "), privacy: .public) (lockState=\(state.lockState.rawValue, privacy: .public))")
            }
        }
        remoteUnlockState = state
        if state.lockState == .unlocked {
            lastLockedRemoteUnlockState = nil
        } else {
            lastLockedRemoteUnlockState = state
        }
    }

    func clearRemoteUnlockState() {
        remoteUnlockState = nil
        lastLockedRemoteUnlockState = nil
    }

    func synthesizedRemoteUnlockState(
        for ack: HermesRealtimeRelayMirrorAck,
        isRemoteUnlockMirrorRequest: Bool
    ) -> HermesRealtimeRelayRemoteUnlockState? {
        guard isRemoteUnlockMirrorRequest else { return nil }
        if var state = lastLockedRemoteUnlockState ?? remoteUnlockState {
            state.sessionId = ack.sessionId ?? state.sessionId
            state.controlOwnerViewerId = ack.viewerId ?? state.controlOwnerViewerId
            state.observedAt = Date()
            return state
        }
        guard let capabilities = ack.remoteUnlockCapabilities,
              capabilities.enabled else { return nil }
        return HermesRealtimeRelayRemoteUnlockState(
            sessionId: ack.sessionId,
            lockState: .unknown,
            backend: capabilities.activeBackend,
            capabilities: capabilities,
            controlOwnerViewerId: ack.viewerId,
            observedAt: Date()
        )
    }

    func makeRemoteUnlockSession(
        uid: String,
        requestID: String
    ) async throws -> (session: HermesRealtimeRelayRemoteUnlockSession, peerNodeId: String) {
        let signingIdentity = try PhoneControlSigningKeyStore.shared.signingIdentity()
        let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingIdentity)
        let trustGateway = LiveDeviceTrustGateway()
        await trustGateway.registerSelfIfNeeded()
        if try await !trustGateway.isSelfTrustedForComputerUseControl() {
            try await confirmLocalAuthentication(reason: "Trust this iPhone for Remote Unlock.")
            try await trustGateway.trustSelfForComputerUseControl()
        }
        try await publishPhoneControlAuthorityWithTrustRetry(
            uid: uid,
            peerNodeId: peerNodeId,
            signingIdentity: signingIdentity,
            trustGateway: trustGateway
        )
        let sessionSigner = PhoneControlSender(
            peerNodeId: peerNodeId,
            uid: uid,
            connectionId: connectionID,
            signingIdentityProvider: { signingIdentity },
            frameSink: { _ in }
        )
        let issuedAt = Date()
        let unsignedSession = HermesRealtimeRelayRemoteUnlockSession(
            requestId: "remote-unlock-\(requestID)",
            sessionId: UUID().uuidString,
            intent: .request,
            requesterDisplayName: deviceDisplayName(),
            viewerDeviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            requestedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(RemoteUnlockPolicy.default.sessionTTLSeconds),
            // Durable device trust is granted once and then reused for locked
            // mirrors. The Mac password is never stored and must be typed for
            // each unlock attempt.
            localAuthenticationSatisfied: true,
            requestedLockState: nil,
            requestedBackend: .openBurnBarVirtualHID,
            authority: Self.emptyAuthorityEnvelope
        )
        return (try sessionSigner.sign(remoteUnlockSession: unsignedSession), peerNodeId)
    }

    func publishPhoneControlAuthorityWithTrustRetry(
        uid: String,
        peerNodeId: String,
        signingIdentity: PhoneControlAuthoritySigningKey,
        trustGateway: LiveDeviceTrustGateway = LiveDeviceTrustGateway()
    ) async throws {
        do {
            try await publishPhoneControlAuthority(
                uid: uid,
                peerNodeId: peerNodeId,
                signingIdentity: signingIdentity
            )
        } catch {
            guard PhoneControlSetupMessage.isFirestorePermissionDenied(error) else { throw error }
            try await trustGateway.trustSelfForComputerUseControl()
            try await publishPhoneControlAuthority(
                uid: uid,
                peerNodeId: peerNodeId,
                signingIdentity: signingIdentity
            )
        }
    }

    func publishPhoneControlAuthority(
        uid: String,
        peerNodeId: String,
        signingIdentity: PhoneControlAuthoritySigningKey
    ) async throws {
        try await PhoneControlAuthorityPublisher.shared.publish(
            uid: uid,
            connectionId: connectionID,
            deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            peerNodeId: peerNodeId,
            publicKeyRepresentation: signingIdentity.publicKeyRepresentation,
            keyKind: signingIdentity.kind
        )
    }

    func makeRemoteUnlockCredentialSender(uid: String) async throws -> PhoneControlSender {
        let signingIdentity = try PhoneControlSigningKeyStore.shared.signingIdentity()
        let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingIdentity)
        let trustGateway = LiveDeviceTrustGateway()
        await trustGateway.registerSelfIfNeeded()
        try await publishPhoneControlAuthorityWithTrustRetry(
            uid: uid,
            peerNodeId: peerNodeId,
            signingIdentity: signingIdentity,
            trustGateway: trustGateway
        )
        // F10: reuse the seal session the phone-control classify established
        // on this connection (the Mac keys its open side by connection id) so
        // remote-unlock credential frames ride sealed too. No session — e.g. a
        // cold unlock at loginwindow before any classify — stays on the
        // legacy lane the Mac still accepts.
        let credentialBaseSink: PhoneControlSender.FrameSink = { frame in
            try await controlStreamCoordinator.send(frame: frame, timeout: 6)
        }
        let credentialSink = ControlSealSessionEstablisher.activeSession(connectionID: connectionID)
            .map { ControlSealSessionEstablisher.sealingFrameSink(credentialBaseSink, session: $0) }
            ?? credentialBaseSink
        return PhoneControlSender(
            peerNodeId: peerNodeId,
            uid: uid,
            connectionId: connectionID,
            signingIdentityProvider: { signingIdentity },
            frameSink: credentialSink
        )
    }

    func confirmLocalAuthentication(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? LAError(.authenticationFailed))
                }
            }
        }
    }

    var mirrorControlStatus: ScreenSharePhoneControlStatus {
        if activeMirrorRequestID != nil && activeMirrorViewerRole == "watcher" {
            return .unavailable("Watching only. Another device controls the Mac.")
        }
        if let phoneControlError {
            return .unavailable(phoneControlError)
        }
        if phoneControlSender != nil {
            if let clipboardStatusMessage {
                return .liveNotice(clipboardStatusMessage)
            }
            return .live
        }
        if phoneControlStarting {
            return .connecting
        }
        return activeMirrorRequestID == nil ? .unavailable("Mirror is read only.") : .connecting
    }

    func startPhoneControlIfPossible(surfaceError: Bool = true, allowTrustRetry: Bool = true) async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            if surfaceError {
                phoneControlError = "Sign in to control your Mac."
            }
            return
        }
        if phoneControlSender != nil, phoneControlConnectionID == connectionID { return }
        phoneControlStarting = true
        defer { phoneControlStarting = false }
        do {
            await LiveDeviceTrustGateway().registerSelfIfNeeded()
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
            let signingIdentity = try PhoneControlSigningKeyStore.shared.signingIdentity()
            let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingIdentity)
            try await PhoneControlAuthorityPublisher.shared.publish(
                uid: uid,
                connectionId: connectionID,
                deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                peerNodeId: peerNodeId,
                publicKeyRepresentation: signingIdentity.publicKeyRepresentation,
                keyKind: signingIdentity.kind
            )
            // F10: establish the control-frame seal when the flag is on and
            // the Mac's heartbeat reply advertised control_seal_v1 (the
            // ensurePhoneControlStreamResponsive round trip above received it).
            let sealSession = await ControlSealSessionEstablisher.establishIfNegotiated(
                uid: uid,
                connectionID: connectionID,
                controllerPeerNodeId: peerNodeId,
                macCapabilities: controlStreamCoordinator.latestMacPresenceCapabilities,
                macRelayPublicKeyBase64: HermesService.shared.selectedConnection.relayPublicKey
            )
            try await sendPhoneControlClassify(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: peerNodeId,
                sealKey: sealSession?.envelope
            )
            let basePhoneControlSink: PhoneControlSender.FrameSink = { frame in
                try await controlStreamCoordinator.send(frame: frame)
            }
            phoneControlSender = PhoneControlSender(
                peerNodeId: peerNodeId,
                uid: uid,
                connectionId: connectionID,
                signingIdentityProvider: { signingIdentity },
                frameSink: sealSession.map { ControlSealSessionEstablisher.sealingFrameSink(basePhoneControlSink, session: $0) } ?? basePhoneControlSink
            )
            phoneControlConnectionID = connectionID
            phoneControlError = nil
            // Keep the authority key doc fresh for long-lived sessions.
            // The Mac's 10-minute TTL on publishedAtMillis would otherwise
            // cause re-fetch failures if the Mac needed to re-register the
            // peer (e.g., after a Mac restart). Refreshing every 8 minutes
            // ensures the doc stays valid.
            startAuthorityRefreshTimer(
                uid: uid,
                peerNodeId: peerNodeId,
                signingIdentity: signingIdentity
            )
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            if allowTrustRetry, PhoneControlSetupMessage.isFirestorePermissionDenied(error) {
                do {
                    try await LiveDeviceTrustGateway().trustSelfForComputerUseControl()
                    Self.debugTrace("phone_control_auto_trusted_retry connectionID=\(connectionID) deviceID=\(MobileDeviceIdentity.loadOrCreateDeviceId())")
                    await startPhoneControlIfPossible(surfaceError: surfaceError, allowTrustRetry: false)
                    return
                } catch {
                    let message = PhoneControlSetupMessage.message(for: error)
                    Self.log.error("phone_control_auto_trust_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    Self.debugTrace("phone_control_auto_trust_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
                    phoneControlError = message
                    return
                }
            }
            let message = PhoneControlSetupMessage.message(for: error)
            Self.log.error("phone_control_start_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("phone_control_start_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
            phoneControlError = message
        }
    }

    func trustThisIPhoneForControl() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        phoneControlStarting = true
        defer { phoneControlStarting = false }
        do {
            try await LiveDeviceTrustGateway().trustSelfForComputerUseControl()
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = nil
            Self.debugTrace("phone_control_device_trusted connectionID=\(connectionID) deviceID=\(MobileDeviceIdentity.loadOrCreateDeviceId())")
            await startPhoneControlIfPossible()
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = PhoneControlSetupMessage.message(for: error)
            Self.log.error("phone_control_trust_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("phone_control_trust_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
        }
    }

    /// Periodically re-publishes the authority key doc so its
    /// `publishedAtMillis` stays within the Mac's 10-minute TTL.
    /// Cancelled automatically when the phone control sender is torn
    /// down or the view disappears.
    func startAuthorityRefreshTimer(
        uid: String,
        peerNodeId: String,
        signingIdentity: PhoneControlAuthoritySigningKey
    ) {
        authorityRefreshTask?.cancel()
        authorityRefreshTask = Task { @MainActor in
            // 8 minutes — comfortably under the 10-minute maximumAge.
            let interval: TimeInterval = 8 * 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, self.phoneControlSender != nil else { break }
                do {
                    try await PhoneControlAuthorityPublisher.shared.publish(
                        uid: uid,
                        connectionId: self.connectionID,
                        deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                        peerNodeId: peerNodeId,
                        publicKeyRepresentation: signingIdentity.publicKeyRepresentation,
                        keyKind: signingIdentity.kind
                    )
                    Self.debugTrace("phone_control_authority_refreshed connectionID=\(self.connectionID)")
                } catch {
                    Self.debugTrace("phone_control_authority_refresh_failed connectionID=\(self.connectionID) error=\(error.localizedDescription)")
                }
            }
        }
    }

    func ensurePhoneControlStreamResponsive(uid: String, connectionID: String) async throws {
        try await controlStreamCoordinator.ensureResponsive(
            uid: uid,
            connectionID: connectionID,
            freshnessInterval: 2.0,
            probeTimeout: 2.5,
            restartTimeout: 6.0
        )
    }

    func sendPhoneControlClassify(
        uid: String,
        connectionID: String,
        peerNodeId: String,
        sealKey: HermesRealtimeRelayControlSealKeyEnvelope? = nil
    ) async throws {
        try await controlStreamCoordinator.send(frame: HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                authorityPeerNodeId: peerNodeId,
                controlSealKey: sealKey
            )
        ))
    }

    func phoneControlDeniedMessage(for denied: HermesRealtimeRelayControlDenied) -> String {
        if denied.reason == .unknown, denied.detail == ComputerUseDenyReason.accessibilityRevoked.rawValue {
            return "Allow OpenBurnBar in Mac System Settings > Privacy & Security > Accessibility, then reopen the mirror."
        }
        switch denied.reason {
        case .entitlement:
            return "Mac control is not enabled for this account."
        case .sessionLimit:
            return "Mac control session limit reached. Reopen the mirror to start a fresh session."
        case .dailyLimit:
            return "Mac control hit today's Computer Use action limit."
        case .softCap:
            return "Mac control is limited while Computer Use is in soft-cap mode."
        case .hardCap:
            return "Mac control is blocked by the Computer Use hard cap."
        case .scope:
            return "The Mac blocked that control action for this screen."
        case .denyRegion:
            return "The Mac blocked control in a protected area."
        case .killSwitch:
            return "Mac control is temporarily disabled."
        case .signatureFailure, .counterReplay, .staleTimestamp:
            if let detail = denied.detail,
               detail == "attestation_required" || detail == "attestation_mismatch" || detail == "mac_attestation_unbound" {
                return "App Check attestation is required on this Mac. Sign in on both devices, reopen the app, then try again."
            }
            return "Mac rejected the control signature. Try the action again."
        case .agentUnavailable:
            return denied.detail ?? "The Mac agent is not available for that control action."
        case .unknown:
            return denied.detail ?? "The Mac rejected that control action."
        }
    }

    func sendClipboardRequest(action: HermesRealtimeRelayClipboardAction) async {
        guard activeMirrorViewerRole == "controller" else {
            setClipboardStatus("Watching only. Take control to use Mac clipboard.")
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            setClipboardStatus("Sign in to control your Mac.")
            return
        }
        let requestId = UUID().uuidString
        let maxBytes = 65_536
        let text: String?
        switch action {
        case .pasteToMac:
            #if canImport(UIKit)
            let phoneText = UIPasteboard.general.string
            #else
            let phoneText: String? = nil
            #endif
            guard let phoneText, !phoneText.isEmpty else {
                setClipboardStatus("Clipboard empty")
                return
            }
            let byteCount = phoneText.utf8.count
            guard byteCount <= maxBytes else {
                setClipboardStatus("Clipboard too large")
                return
            }
            text = phoneText
        case .grabFromMac:
            text = nil
        }

        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            setClipboardStatus(error.localizedDescription)
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else { return }
        do {
            // The control.classify handshake already ran during
            // startPhoneControlIfPossible(). See sendPhoneControlIntent
            // for the full rationale.
            let placeholder = HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "",
                counter: 0,
                timestamp: Date(timeIntervalSince1970: 0),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
            let request = HermesRealtimeRelayClipboardRequest(
                requestId: requestId,
                action: action,
                contentType: "text/plain",
                text: text,
                maxBytes: maxBytes,
                clientIntentId: UUID().uuidString,
                authority: placeholder
            )
            pendingClipboardRequests[requestId] = action
            _ = try await phoneControlSender.send(clipboardRequest: request)
        } catch {
            pendingClipboardRequests.removeValue(forKey: requestId)
            self.phoneControlSender = nil
            phoneControlConnectionID = nil
            setClipboardStatus(error.localizedDescription)
        }
    }

    func handleClipboardResponse(_ response: HermesRealtimeRelayClipboardResponse) {
        guard let pendingAction = pendingClipboardRequests.removeValue(forKey: response.requestId),
              pendingAction == response.action else {
            return
        }
        switch response.status {
        case .accepted:
            switch response.action {
            case .pasteToMac:
                setClipboardStatus("Pasted to Mac")
            case .grabFromMac:
                guard response.contentType == "text/plain",
                      let text = response.text else {
                    setClipboardStatus("Mac denied clipboard")
                    return
                }
                #if canImport(UIKit)
                UIPasteboard.general.string = text
                #endif
                setClipboardStatus("Mac clipboard copied")
            }
        case .empty:
            setClipboardStatus("Clipboard empty")
        case .denied:
            setClipboardStatus("Mac denied clipboard")
        case .tooLarge:
            setClipboardStatus("Clipboard too large")
        case .unsupported, .error:
            setClipboardStatus(response.detail == "too_large" ? "Clipboard too large" : "Mac denied clipboard")
        }
    }

    func setClipboardStatus(_ message: String) {
        clipboardStatusMessage = message
        phoneControlError = nil
    }

    func shouldRefreshRemoteUnlockSession(after detail: String) -> Bool {
        switch detail {
        case "session_mismatch",
             "session_expired",
             "signature_failure",
             "counter_replay",
             "stale_timestamp":
            return true
        default:
            return false
        }
    }

    func shouldRetryMirrorRequestAfterRefreshingControlStream(_ error: Error) -> Bool {
        guard let controlError = error as? MediaControlStreamCoordinator.ControlStreamError else {
            return false
        }
        switch controlError {
        case .timedOutWaitingForLiveStream,
             .timedOutSendingFrame,
             .macDidNotRespond:
            return true
        case .notLive:
            return false
        }
    }

    func remoteUnlockMessage(for detail: String) -> String {
        switch detail {
        case "session_mismatch", "session_expired":
            return "Unlock session refreshed. Enter your Mac password again."
        case "signature_failure", "counter_replay", "stale_timestamp":
            return "Secure unlock lane refreshed. Enter your Mac password again."
        case "credential_submitted":
            return "Password sent to Mac login window."
        case "credential_received":
            return "Mac received the password. Entering it at the login window..."
        case "credential_saved":
            return "One-tap Remote Unlock is ready on this device."
        case "saved_credential_deleted":
            return "Saved Remote Unlock credential removed from this device."
        case "untrusted_controller":
            return "Take control from this device, then try unlocking again."
        case "control_owned_by_other_viewer":
            return "Another device has control of this mirror."
        case "remote_access_daemon_unavailable", "remote_access_daemon_socket_unavailable":
            return "Remote Unlock helper is not reachable on the Mac."
        case "remote_access_daemon_rejected":
            return "Remote Unlock helper rejected the password request."
        case "virtual_hid_bridge_unavailable", "virtual_hid_bridge_socket_unavailable":
            return "Remote Unlock needs the Mac virtual keyboard bridge to be installed and running."
        case "virtual_hid_device_unavailable":
            return "macOS blocked the Remote Unlock virtual keyboard. Install the approved OpenBurnBar helper, then try again."
        case "unsupported_keyboard_layout":
            return "This Mac password has characters Remote Unlock cannot type yet."
        case "virtual_hid_report_failed", "virtual_hid_bridge_write_failed", "virtual_hid_bridge_read_failed", "virtual_hid_bridge_timed_out":
            return "Remote Unlock could not send keys through the Mac virtual keyboard."
        case "login_session_worker_failed", "login_session_worker_launch_failed", "login_session_worker_input_failed":
            return "Remote Unlock could not reach the Mac login session."
        case "login_session_worker_timed_out":
            return "The Mac login window took too long to respond. Tap One-tap unlock again."
        default:
            return detail
        }
    }

    func refreshRemoteUnlockSessionAfterCredentialRejection() async {
        guard !remoteUnlockRefreshInFlight else { return }
        remoteUnlockRefreshInFlight = true
        defer { remoteUnlockRefreshInFlight = false }
        await requestMirror(forceRemoteUnlockSession: true)
        if phoneControlError == nil {
            phoneControlError = "Unlock session refreshed. Enter your Mac password again."
        }
    }

    func saveRemoteUnlockCredential(password: String) async {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            phoneControlError = "Enter your Mac password before saving it for one-tap unlock."
            return
        }
        let capabilities = (remoteUnlockState ?? lastAck?.remoteUnlockState)?.capabilities
        guard capabilities?.enabled == true,
              capabilities?.allowsSavedCredentialUnlock == true else {
            phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
            return
        }
        do {
            try await confirmLocalAuthentication(reason: "Save this Mac password for one-tap Remote Unlock on this device.")
            guard let storeKey = remoteUnlockCredentialStoreKey() else {
                phoneControlError = "Remote Unlock is not ready on this Mac."
                return
            }
            try RemoteUnlockSavedCredentialStore.shared.save(trimmedPassword, storeKey: storeKey)
            refreshSavedCredentialAvailability()
            phoneControlError = remoteUnlockMessage(for: "credential_saved")
        } catch {
            phoneControlError = "Saved Remote Unlock setup was cancelled."
        }
    }

    func sendSavedRemoteUnlockCredential() async {
        phoneControlError = "Loading saved Remote Unlock credential..."
        Self.log.info("remote_unlock_saved_credential_load_start connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("remote_unlock_saved_credential_load_start connectionID=\(connectionID)")
        remoteUnlockDiagnosticMessage = "one-tap: loading saved credential"
        let capabilities = (remoteUnlockState ?? lastAck?.remoteUnlockState)?.capabilities
        guard capabilities?.enabled == true,
              capabilities?.allowsSavedCredentialUnlock == true else {
            phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
            remoteUnlockDiagnosticMessage = "one-tap blocked: capability not ready"
            Self.log.error("remote_unlock_saved_credential_load_blocked reason=capability_not_ready connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_load_blocked reason=capability_not_ready connectionID=\(connectionID)")
            return
        }
        do {
            guard let storeKey = remoteUnlockCredentialStoreKey() else {
                phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
                remoteUnlockDiagnosticMessage = "one-tap blocked: missing store key"
                Self.log.error("remote_unlock_saved_credential_load_blocked reason=missing_store_key connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("remote_unlock_saved_credential_load_blocked reason=missing_store_key connectionID=\(connectionID)")
                return
            }
            let password = try RemoteUnlockSavedCredentialStore.shared.load(
                storeKey: storeKey,
                reason: "Unlock your Mac with the saved Remote Unlock credential."
            )
            Self.log.info("remote_unlock_saved_credential_loaded storeKey=\(storeKey, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_loaded storeKey=\(storeKey) connectionID=\(connectionID)")
            await sendRemoteUnlockCredential(password: password, credentialKind: .savedPassword)
        } catch {
            refreshSavedCredentialAvailability()
            phoneControlError = "Saved Remote Unlock credential is unavailable. Type your Mac password instead."
            remoteUnlockDiagnosticMessage = "one-tap failed: saved credential unavailable"
            Self.log.error("remote_unlock_saved_credential_load_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_load_failed connectionID=\(connectionID) error=\(String(describing: error))")
        }
    }

    func deleteSavedRemoteUnlockCredential() {
        guard let storeKey = remoteUnlockCredentialStoreKey() else {
            remoteUnlockSavedCredentialAvailable = false
            return
        }
        RemoteUnlockSavedCredentialStore.shared.delete(storeKey: storeKey)
        refreshSavedCredentialAvailability()
        phoneControlError = remoteUnlockMessage(for: "saved_credential_deleted")
    }

    func refreshSavedCredentialAvailability() {
        guard let storeKey = remoteUnlockCredentialStoreKey() else {
            remoteUnlockSavedCredentialAvailable = false
            return
        }
        remoteUnlockSavedCredentialAvailable = RemoteUnlockSavedCredentialStore.shared.hasCredential(storeKey: storeKey)
    }

    func remoteUnlockCredentialStoreKey() -> String? {
        RemoteUnlockCredentialStoreKey.make(
            state: remoteUnlockState ?? lastAck?.remoteUnlockState,
            phoneControlConnectionID: phoneControlConnectionID,
            mirrorConnectionID: connectionID,
            mirrorRequestID: activeMirrorRequestID
        )
    }

    func sendRemoteUnlockCredential(
        password: String,
        credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind = .typedPassword
    ) async {
        Self.log.info("remote_unlock_credential_prepare_start kind=\(credentialKind.rawValue, privacy: .public) connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("remote_unlock_credential_prepare_start kind=\(credentialKind.rawValue) connectionID=\(connectionID)")
        remoteUnlockDiagnosticMessage = "credential: preparing"
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            phoneControlError = "Enter your Mac password."
            remoteUnlockDiagnosticMessage = "credential blocked: empty password"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=empty_password connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=empty_password connectionID=\(connectionID)")
            return
        }
        controlStreamCoordinator.suspendBackgroundTraffic(for: 45)
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control from this device to unlock the Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: viewer is not controller"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=not_controller role=\(activeMirrorViewerRole ?? "nil", privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=not_controller role=\(activeMirrorViewerRole ?? "nil") connectionID=\(connectionID)")
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to unlock your Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: missing user"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=missing_uid connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=missing_uid connectionID=\(connectionID)")
            return
        }
        let state = remoteUnlockState ?? lastAck?.remoteUnlockState
        guard let state, state.lockState != .unlocked else {
            phoneControlError = "The Mac is already unlocked."
            remoteUnlockDiagnosticMessage = "credential blocked: Mac already unlocked"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=already_unlocked connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=already_unlocked connectionID=\(connectionID)")
            return
        }
        let capabilities = state.capabilities
        guard capabilities.enabled,
              capabilities.allowsCredentialPaste,
              let sessionId = state.sessionId,
              let recipientKeyId = capabilities.credentialRecipientKeyId,
              let recipientPublicKey = capabilities.credentialRecipientPublicKeyBase64,
              let algorithm = capabilities.credentialEnvelopeAlgorithm else {
            phoneControlError = "Remote Unlock is not ready on this Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: Mac capability incomplete"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=capability_incomplete connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=capability_incomplete connectionID=\(connectionID)")
            return
        }
        guard algorithm == RemoteUnlockCredentialEnvelopeCrypto.algorithm else {
            phoneControlError = "Remote Unlock needs an app update on this device."
            remoteUnlockDiagnosticMessage = "credential blocked: encryption mismatch"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=algorithm_mismatch algorithm=\(algorithm, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=algorithm_mismatch algorithm=\(algorithm) connectionID=\(connectionID)")
            return
        }

        let credentialSender: PhoneControlSender
        do {
            if RemoteUnlockCredentialSenderReusePolicy.shouldReuseExistingSender(
                phoneControlConnectionID: phoneControlConnectionID,
                currentConnectionID: connectionID
            ),
               let existingSender = phoneControlSender {
                credentialSender = existingSender
            } else {
                let sender = try await makeRemoteUnlockCredentialSender(uid: uid)
                phoneControlSender = sender
                phoneControlConnectionID = connectionID
                credentialSender = sender
                Self.debugTrace("remote_unlock_credential_sender_rebuilt connectionID=\(connectionID)")
            }
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = PhoneControlSetupMessage.message(for: error)
            remoteUnlockDiagnosticMessage = "credential blocked: sender setup failed"
            Self.log.error("remote_unlock_credential_sender_setup_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            Self.debugTrace("remote_unlock_credential_sender_setup_failed connectionID=\(connectionID) error=\(String(describing: error))")
            return
        }

        do {
            do {
                try await controlStreamCoordinator.ensureResponsive(
                    uid: uid,
                    connectionID: connectionID,
                    freshnessInterval: 2,
                    probeTimeout: 2.5,
                    restartTimeout: 6
                )
            } catch {
                phoneControlSender = nil
                phoneControlConnectionID = nil
                phoneControlError = "Mac control stream is not responding. Reopen Mercury and try again."
                remoteUnlockDiagnosticMessage = "credential blocked: control stream probe failed"
                Self.log.error("remote_unlock_credential_stream_probe_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                Self.debugTrace("remote_unlock_credential_stream_probe_failed connectionID=\(connectionID) error=\(String(describing: error))")
                return
            }

            let requestId = UUID().uuidString
            let clientIntentId = UUID().uuidString
            let requestedAt = Date()
            let expiresAt = requestedAt.addingTimeInterval(RemoteUnlockPolicy.default.credentialTTLSeconds)
            let sealed = try RemoteUnlockCredentialEnvelopeCrypto.seal(
                credential: trimmedPassword,
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: credentialKind,
                recipientKeyId: recipientKeyId,
                recipientPublicKeyBase64: recipientPublicKey,
                algorithm: algorithm
            )
            let envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: credentialKind,
                recipientKeyId: recipientKeyId,
                algorithm: algorithm,
                ciphertextBase64: sealed.ciphertextBase64,
                aadBase64: sealed.aadBase64,
                redactedByteCount: sealed.redactedByteCount,
                requestedAt: requestedAt,
                expiresAt: expiresAt,
                authority: Self.emptyAuthorityEnvelope
            )
            pendingRemoteUnlockCredentialRequestID = requestId
            remoteUnlockCredentialAckTimeoutTask?.cancel()
            phoneControlError = "Sending password to Mac..."
            remoteUnlockDiagnosticMessage = "credential: writing frame"
            Self.log.info("remote_unlock_credential_send_start requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_send_start requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            _ = try await credentialSender.send(remoteUnlockCredential: envelope)
            Self.log.info("remote_unlock_credential_frame_written requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_frame_written requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            phoneControlError = "Password sent. Waiting for Mac..."
            remoteUnlockDiagnosticMessage = "credential: frame written; waiting for Mac result"
            remoteUnlockCredentialAckTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.remoteUnlockCredentialAckTimeoutNanoseconds)
                guard pendingRemoteUnlockCredentialRequestID == requestId else { return }
                pendingRemoteUnlockCredentialRequestID = nil
                phoneControlError = "Still waiting for the Mac. If the login screen did not react, tap One-tap unlock again."
                remoteUnlockDiagnosticMessage = "credential timeout: Mac result not received"
                Self.log.error("remote_unlock_credential_ack_timeout requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("remote_unlock_credential_ack_timeout requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            }
        } catch {
            self.phoneControlSender = nil
            phoneControlConnectionID = nil
            if let pendingRemoteUnlockCredentialRequestID {
                Self.log.error("remote_unlock_credential_send_failed requestID=\(pendingRemoteUnlockCredentialRequestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                Self.debugTrace("remote_unlock_credential_send_failed requestID=\(pendingRemoteUnlockCredentialRequestID) error=\(String(describing: error))")
            }
            pendingRemoteUnlockCredentialRequestID = nil
            remoteUnlockCredentialAckTimeoutTask?.cancel()
            remoteUnlockCredentialAckTimeoutTask = nil
            phoneControlError = error.localizedDescription
            remoteUnlockDiagnosticMessage = "credential failed: \(error.localizedDescription)"
        }
    }

    func requestRemoteUnlockInputSetup() async {
        guard activeMirrorViewerRole == "controller" else {
            remoteUnlockDiagnosticMessage = "Take control from this iPhone before requesting Mac setup."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            remoteUnlockDiagnosticMessage = "Sign in to request Mac setup."
            return
        }
        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
            if phoneControlSender == nil {
                await startPhoneControlIfPossible()
            }
            guard let phoneControlSender else {
                remoteUnlockDiagnosticMessage = "Mac control stream is not ready yet."
                return
            }
            let item = SystemPermissionItem(
                kind: .systemExtension,
                threadId: activeMirrorSessionId ?? connectionID,
                status: .needsAccess,
                instructions: "Install and activate OpenBurnBar locked-screen input on the Mac.",
                source: .iosHeuristic
            )
            let sender = SystemPermissionGrantSender(senderFactory: { phoneControlSender })
            _ = try await sender.sendGrant(item: item, action: .promptAndOpenSettings)
            remoteUnlockDiagnosticMessage = "Mac setup requested. Approve the OpenBurnBar prompt on the Mac."
            phoneControlError = nil
        } catch {
            remoteUnlockDiagnosticMessage = "Mac setup request failed: \(error.localizedDescription)"
            Self.debugTrace("remote_unlock_input_setup_request_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
        }
    }

    func requestRemoteUnlockInputSetupFromOverlay() {
        Task { await requestRemoteUnlockInputSetup() }
    }

    func sendPhoneControlIntent(
        kind: HermesRealtimeRelayInputIntent.Kind,
        displayId: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        mouseButton: Int? = nil
    ) async {
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control from this device to click or type."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            Self.debugTrace("phone_control_stream_not_responsive kind=\(kind.rawValue) connectionID=\(connectionID) error=\(error.localizedDescription)")
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else {
            Self.debugTrace("phone_control_no_sender_after_start kind=\(kind.rawValue) connectionID=\(connectionID)")
            return
        }
        // The control.classify handshake already ran during
        // startPhoneControlIfPossible(). Re-sending it on every intent
        // caused the Mac to re-fetch the authority key from Firestore each
        // time. After the key doc's 10-minute publishedAtMillis TTL
        // expired, every re-fetch failed with `expired`, surfacing as
        // "Mac rejected the control signature."
        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: kind,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedX2: normalizedX2,
            normalizedY2: normalizedY2,
            text: text,
            key: key,
            modifiers: modifiers,
            mouseButton: mouseButton,
            authority: emptyAuthority
        )
        do {
            Self.debugTrace("phone_control_send kind=\(kind.rawValue) connectionID=\(connectionID)")
            _ = try await phoneControlSender.send(intent: intent)
            phoneControlError = nil
        } catch let error as PhoneControlSender.SendError where error == .attestationRequired {
            phoneControlError = "App Check attestation is required. Reopen the app after signing in, then try again."
            Self.debugTrace("phone_control_send_failed_attestation_required connectionID=\(connectionID)")
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            if let denied = frameDetailForAttestationDenial(error) {
                phoneControlError = denied
            } else {
                phoneControlError = error.localizedDescription
            }
            Self.debugTrace("phone_control_send_failed kind=\(kind.rawValue) connectionID=\(connectionID) error=\(error.localizedDescription)")
        }
    }

    func frameDetailForAttestationDenial(_ error: Error) -> String? {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("attestation_required")
            || message.localizedCaseInsensitiveContains("attestation_mismatch")
            || message.localizedCaseInsensitiveContains("mac_attestation_unbound") {
            return "App Check attestation is required on this Mac. Sign in on both devices and try again."
        }
        return nil
    }

    func sendPhoneControlContextTarget(
        normalizedX: Double,
        normalizedY: Double,
        instruction: String,
        runtime: String,
        threadId: String?
    ) async {
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control to hand this target to an agent."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else {
            return
        }
        // The control.classify handshake already ran during
        // startPhoneControlIfPossible(). See sendPhoneControlIntent
        // for the full rationale.

        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )

        let displayId = selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
        let target = HermesRealtimeRelayAgentContextTarget(
            requestId: UUID().uuidString,
            sessionId: activeMirrorSessionId ?? lastAck?.sessionId,
            runtime: runtime,
            threadId: threadId,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedRect: nil,
            instruction: instruction,
            focusContext: nil,
            clientIntentId: UUID().uuidString,
            requestedAt: Date(),
            authority: emptyAuthority
        )

        do {
            _ = try await phoneControlSender.send(contextTarget: target)
            phoneControlError = nil
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
        }
    }
}
