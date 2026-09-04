#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import OSLog
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

public protocol RemoteClipboardPasteboard: Sendable {
    func readString() -> String?
    func writeString(_ text: String) throws
}

public protocol RemoteClipboardInputControlling: Sendable {
    func isAccessibilityTrusted() -> Bool
    @discardableResult func pasteShortcut() throws -> Double
}

public protocol RemoteClipboardContextInspecting: Sendable {
    func currentScopeContext() -> ComputerUseScopeContext
    func focusedDenyReason() -> ComputerUseAccessibilityDenyReason?
}

/// Read/create the HPKE recipient key material used to certify and decrypt Remote Unlock
/// credentials. A failure here is security-relevant: it must never silently certify with
/// half-formed (missing/empty) key material, and its loss must be observable. This seam lets
/// the controller fail closed + log a key-material fault, and lets tests inject a faulting store.
protocol RemoteUnlockCredentialKeyProviding: Sendable {
    func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey
    func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial
}

extension RemoteUnlockCredentialKeyStore: RemoteUnlockCredentialKeyProviding {}

public final class GeneralRemoteClipboardPasteboard: RemoteClipboardPasteboard, Sendable {
    private struct State {
        var pasteboard: NSPasteboard
    }

    // `NSPasteboard` is an AppKit reference type that is not `Sendable`, and the
    // conformed-to `RemoteClipboardPasteboard` protocol is nonisolated, so the
    // type cannot be `@MainActor`. The lock fully mediates access to the stored
    // reference, yielding genuine `Sendable` conformance without `@unchecked`.
    private let state: OSAllocatedUnfairLock<State>

    public init(pasteboard: NSPasteboard = .general) {
        self.state = OSAllocatedUnfairLock(uncheckedState: State(pasteboard: pasteboard))
    }

    public func readString() -> String? {
        state.withLockUnchecked { $0.pasteboard.string(forType: .string) }
    }

    public func writeString(_ text: String) throws {
        state.withLockUnchecked { state in
            state.pasteboard.clearContents()
            state.pasteboard.setString(text, forType: .string)
        }
    }
}

extension MacInputController: RemoteClipboardInputControlling {
    @discardableResult
    public func pasteShortcut() throws -> Double {
        try shortcut(key: "v", modifiers: ["command"])
    }
}

extension MacAccessibilityInspector: RemoteClipboardContextInspecting {
    public func currentScopeContext() -> ComputerUseScopeContext {
        frontmostScopeContext()
    }

    public func focusedDenyReason() -> ComputerUseAccessibilityDenyReason? {
        denyReason(for: focusedSnapshot())
    }
}

@MainActor
public final class RemoteClipboardController {
    public static let defaultMaxBytes = 65_536
    public static let supportedContentType = "text/plain"

    public struct RuntimeContext {
        public var activeSessionId: ComputerUseSessionID?
        public var state: ComputerUseSessionState?
        public var configuration: ComputerUseSessionCoordinator.Configuration
        public var auditLogger: ComputerUseAuditLogger?
        public var scopeRules: [ComputerUseScopeRule]
        public var validator: PhoneControlAuthorityValidator
        public var isDirectPhoneControl: Bool
        public var attestation: PhoneControlAttestationRequirement
        public var phoneSessionFirstActionConfirmed: Bool

        public init(
            activeSessionId: ComputerUseSessionID?,
            state: ComputerUseSessionState?,
            configuration: ComputerUseSessionCoordinator.Configuration,
            auditLogger: ComputerUseAuditLogger?,
            scopeRules: [ComputerUseScopeRule],
            validator: PhoneControlAuthorityValidator,
            isDirectPhoneControl: Bool,
            attestation: PhoneControlAttestationRequirement = .none,
            phoneSessionFirstActionConfirmed: Bool = false
        ) {
            self.activeSessionId = activeSessionId
            self.state = state
            self.configuration = configuration
            self.auditLogger = auditLogger
            self.scopeRules = scopeRules
            self.validator = validator
            self.isDirectPhoneControl = isDirectPhoneControl
            self.attestation = attestation
            self.phoneSessionFirstActionConfirmed = phoneSessionFirstActionConfirmed
        }
    }

    public struct Result {
        public var response: HermesRealtimeRelayClipboardResponse
        public var action: ComputerUseAction?
        public var auditEntry: ComputerUseAuditEntry?
        public var executed: Bool
        public var rejected: Bool
        public var denyReason: ComputerUseDenyReason?
    }

    private let pasteboard: any RemoteClipboardPasteboard
    private let inputController: any RemoteClipboardInputControlling
    private let inspector: any RemoteClipboardContextInspecting
    private let gate: any ComputerUseCapabilityGate
    private let scopeMatcher: ComputerUseScopeMatcher

    public init(
        pasteboard: any RemoteClipboardPasteboard = GeneralRemoteClipboardPasteboard(),
        inputController: any RemoteClipboardInputControlling = MacInputController(),
        inspector: any RemoteClipboardContextInspecting = MacAccessibilityInspector(),
        gate: any ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        scopeMatcher: ComputerUseScopeMatcher = ComputerUseScopeMatcher()
    ) {
        self.pasteboard = pasteboard
        self.inputController = inputController
        self.inspector = inspector
        self.gate = gate
        self.scopeMatcher = scopeMatcher
    }

    public func handle(
        request: HermesRealtimeRelayClipboardRequest,
        context: RuntimeContext
    ) -> Result {
        let action = ComputerUseAction.remoteClipboard(descriptor(for: request))

        do {
            _ = try context.validator.validate(
                envelope: request.authority,
                clipboardRequest: request,
                attestation: context.attestation,
                now: Date(),
                consumeCounter: context.phoneSessionFirstActionConfirmed
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            return Result(
                response: response(for: request, status: .denied, detail: validationDetail(for: error)),
                action: action,
                auditEntry: nil,
                executed: false,
                rejected: true,
                denyReason: .signatureFailure
            )
        } catch {
            return Result(
                response: response(for: request, status: .denied, detail: "signature_failure"),
                action: action,
                auditEntry: nil,
                executed: false,
                rejected: true,
                denyReason: .signatureFailure
            )
        }

        guard let sessionId = context.activeSessionId,
              let state = context.state,
              context.isDirectPhoneControl,
              state.manifest.phoneViewerNodeId == request.authority.peerNodeId else {
            let entry = appendAuditEntry(
                logger: context.auditLogger,
                action: action,
                approvedBy: .denied,
                denyReason: ComputerUseDenyReason.scopeDenied.rawValue,
                context: inspector.currentScopeContext(),
                macHostNodeId: context.configuration.macHostNodeId
            )
            return Result(
                response: response(for: request, status: .denied, detail: "untrusted_controller"),
                action: action,
                auditEntry: entry,
                executed: false,
                rejected: true,
                denyReason: .scopeDenied
            )
        }
        _ = sessionId

        guard request.contentType == Self.supportedContentType else {
            let entry = appendAuditEntry(
                logger: context.auditLogger,
                action: action,
                approvedBy: .denied,
                denyReason: HermesRealtimeRelayClipboardStatus.unsupported.rawValue,
                context: inspector.currentScopeContext(),
                macHostNodeId: context.configuration.macHostNodeId
            )
            return Result(
                response: response(for: request, status: .unsupported, detail: "unsupported_content_type"),
                action: action,
                auditEntry: entry,
                executed: false,
                rejected: true,
                denyReason: nil
            )
        }

        let scopeContext = inspector.currentScopeContext()
        let scopeOutcome = scopeMatcher.evaluate(
            rules: context.scopeRules,
            context: scopeContext
        )
        let accessibilityDeny = inspector.focusedDenyReason()
        let capability = ComputerUseCapabilityContext(
            entitlement: context.configuration.entitlement,
            envelope: context.configuration.budgetEnvelope,
            usage: context.configuration.quotaUsage,
            session: state,
            concurrentSessionActive: false,
            killSwitch: context.configuration.killSwitch,
            accessibilityTrusted: inputController.isAccessibilityTrusted(),
            originatedFromPhone: true,
            phoneControlRespectsDenyRegions: context.configuration.phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: context.phoneSessionFirstActionConfirmed,
            clipboardConsentGranted: context.configuration.clipboardConsentGranted
        )

        switch gate.check(
            action: action,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: accessibilityDeny,
            context: capability
        ) {
        case .denied(let reason):
            let entry = appendAuditEntry(
                logger: context.auditLogger,
                action: action,
                approvedBy: .denied,
                denyReason: reason.rawValue,
                context: scopeContext,
                macHostNodeId: context.configuration.macHostNodeId
            )
            return Result(
                response: response(for: request, status: .denied, detail: reason.rawValue),
                action: action,
                auditEntry: entry,
                executed: false,
                rejected: true,
                denyReason: reason
            )
        case .allowed(let approvedBy):
            if approvedBy == .mac && !context.phoneSessionFirstActionConfirmed {
                return Result(
                    response: response(for: request, status: .denied, detail: "phone_first_action_approval_required"),
                    action: action,
                    auditEntry: nil,
                    executed: false,
                    rejected: false,
                    denyReason: nil
                )
            }
            return perform(request: request, action: action, context: context, scopeContext: scopeContext)
        }
    }

    private func perform(
        request: HermesRealtimeRelayClipboardRequest,
        action: ComputerUseAction,
        context: RuntimeContext,
        scopeContext: ComputerUseScopeContext
    ) -> Result {
        switch request.action {
        case .pasteToMac:
            return pasteToMac(request: request, action: action, context: context, scopeContext: scopeContext)
        case .grabFromMac:
            return grabFromMac(request: request, action: action, context: context, scopeContext: scopeContext)
        }
    }

    private func pasteToMac(
        request: HermesRealtimeRelayClipboardRequest,
        action: ComputerUseAction,
        context: RuntimeContext,
        scopeContext: ComputerUseScopeContext
    ) -> Result {
        guard let text = request.text, !text.isEmpty else {
            return rejectedResult(
                request: request,
                action: action,
                context: context,
                scopeContext: scopeContext,
                status: .empty,
                detail: "empty"
            )
        }
        let byteCount = text.utf8.count
        guard byteCount <= clampedMaxBytes(request.maxBytes) else {
            return rejectedResult(
                request: request,
                action: action,
                context: context,
                scopeContext: scopeContext,
                status: .tooLarge,
                byteCount: byteCount,
                detail: "too_large"
            )
        }

        do {
            try pasteboard.writeString(text)
            _ = try inputController.pasteShortcut()
            let entry = appendAuditEntry(
                logger: context.auditLogger,
                action: action,
                approvedBy: .phone,
                context: scopeContext,
                macHostNodeId: context.configuration.macHostNodeId
            )
            return Result(
                response: response(
                    for: request,
                    status: .accepted,
                    contentType: Self.supportedContentType,
                    byteCount: byteCount
                ),
                action: action,
                auditEntry: entry,
                executed: true,
                rejected: false,
                denyReason: nil
            )
        } catch {
            return rejectedResult(
                request: request,
                action: action,
                context: context,
                scopeContext: scopeContext,
                status: .error,
                byteCount: byteCount,
                detail: "dispatch_error"
            )
        }
    }

    private func grabFromMac(
        request: HermesRealtimeRelayClipboardRequest,
        action: ComputerUseAction,
        context: RuntimeContext,
        scopeContext: ComputerUseScopeContext
    ) -> Result {
        guard let text = pasteboard.readString(), !text.isEmpty else {
            return rejectedResult(
                request: request,
                action: action,
                context: context,
                scopeContext: scopeContext,
                status: .empty,
                detail: "empty"
            )
        }
        let byteCount = text.utf8.count
        guard byteCount <= clampedMaxBytes(request.maxBytes) else {
            return rejectedResult(
                request: request,
                action: action,
                context: context,
                scopeContext: scopeContext,
                status: .tooLarge,
                byteCount: byteCount,
                detail: "too_large"
            )
        }
        let entry = appendAuditEntry(
            logger: context.auditLogger,
            action: action,
            approvedBy: .phone,
            context: scopeContext,
            macHostNodeId: context.configuration.macHostNodeId
        )
        return Result(
            response: response(
                for: request,
                status: .accepted,
                contentType: Self.supportedContentType,
                text: text,
                byteCount: byteCount
            ),
            action: action,
            auditEntry: entry,
            executed: true,
            rejected: false,
            denyReason: nil
        )
    }

    private func rejectedResult(
        request: HermesRealtimeRelayClipboardRequest,
        action: ComputerUseAction,
        context: RuntimeContext,
        scopeContext: ComputerUseScopeContext,
        status: HermesRealtimeRelayClipboardStatus,
        byteCount: Int? = nil,
        detail: String
    ) -> Result {
        let entry = appendAuditEntry(
            logger: context.auditLogger,
            action: action,
            approvedBy: .denied,
            denyReason: detail,
            context: scopeContext,
            macHostNodeId: context.configuration.macHostNodeId
        )
        return Result(
            response: response(for: request, status: status, byteCount: byteCount, detail: detail),
            action: action,
            auditEntry: entry,
            executed: false,
            rejected: true,
            denyReason: nil
        )
    }

    private func appendAuditEntry(
        logger: ComputerUseAuditLogger?,
        action: ComputerUseAction,
        approvedBy: ComputerUseAuditEntry.ApprovedBy,
        denyReason: String? = nil,
        context: ComputerUseScopeContext,
        macHostNodeId: String?
    ) -> ComputerUseAuditEntry? {
        guard let logger else { return nil }
        do {
            let entry = try logger.makeEntry(
                for: action,
                approvedBy: approvedBy,
                denyReason: denyReason,
                macHostNodeId: macHostNodeId,
                scopeContext: context
            )
            try logger.append(entry)
            return entry
        } catch {
            return nil
        }
    }

    private func descriptor(for request: HermesRealtimeRelayClipboardRequest) -> RemoteClipboardActionDescriptor {
        RemoteClipboardActionDescriptor(
            kind: RemoteClipboardActionDescriptor.Kind(rawValue: request.action.rawValue) ?? .pasteToMac,
            requestId: request.requestId,
            contentType: request.contentType,
            byteCount: request.text?.utf8.count,
            maxBytes: request.maxBytes
        )
    }

    private func response(
        for request: HermesRealtimeRelayClipboardRequest,
        status: HermesRealtimeRelayClipboardStatus,
        contentType: String? = nil,
        text: String? = nil,
        byteCount: Int? = nil,
        detail: String? = nil
    ) -> HermesRealtimeRelayClipboardResponse {
        HermesRealtimeRelayClipboardResponse(
            requestId: request.requestId,
            action: request.action,
            status: status,
            contentType: contentType,
            text: text,
            byteCount: byteCount,
            detail: detail
        )
    }

    private func clampedMaxBytes(_ value: Int) -> Int {
        min(max(value, 0), Self.defaultMaxBytes)
    }

    private func validationDetail(for error: PhoneControlAuthorityValidator.ValidationError) -> String {
        error.auditDetailToken
    }
}

@MainActor
final class RemoteUnlockCredentialController {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "RemoteUnlock")
    private static func debugTrace(_ message: String) {
        // Session/peer identifiers and lock-state transitions are debug
        // diagnostics; keep them out of the unified log in release builds.
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

    struct RuntimeContext {
        var validator: PhoneControlAuthorityValidator
        var activeSessionId: ComputerUseSessionID?
        var state: ComputerUseSessionState?
        var isDirectPhoneControl: Bool
        var authorizedPeerNodeId: String?
        var attestation: PhoneControlAttestationRequirement
        var readiness: MacRemoteUnlockReadinessService

        @MainActor init(
            validator: PhoneControlAuthorityValidator,
            activeSessionId: ComputerUseSessionID?,
            state: ComputerUseSessionState?,
            isDirectPhoneControl: Bool,
            authorizedPeerNodeId: String?,
            attestation: PhoneControlAttestationRequirement = .none,
            readiness: MacRemoteUnlockReadinessService = .shared
        ) {
            self.validator = validator
            self.activeSessionId = activeSessionId
            self.state = state
            self.isDirectPhoneControl = isDirectPhoneControl
            self.authorizedPeerNodeId = authorizedPeerNodeId
            self.attestation = attestation
            self.readiness = readiness
        }
    }

    private let inputController: MacInputController
    private let keyStore: any RemoteUnlockCredentialKeyProviding
    private let policy: RemoteUnlockPolicy

    init(
        inputController: MacInputController = MacInputController(),
        keyStore: any RemoteUnlockCredentialKeyProviding = RemoteUnlockCredentialKeyStore.shared,
        policy: RemoteUnlockPolicy = .default
    ) {
        self.inputController = inputController
        self.keyStore = keyStore
        self.policy = policy
    }

    func handle(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        context: RuntimeContext
    ) async -> HermesRealtimeRelayRemoteUnlockResult {
        func result(
            _ status: HermesRealtimeRelayRemoteUnlockResult.Status,
            detail: String,
            lockState: HermesRealtimeRelayMacLockState? = nil
        ) -> HermesRealtimeRelayRemoteUnlockResult {
            HermesRealtimeRelayRemoteUnlockResult(
                requestId: credential.requestId,
                sessionId: credential.sessionId,
                status: status,
                lockState: lockState,
                backend: context.readiness.capabilities().activeBackend,
                detail: detail,
                completedAt: Date()
            )
        }

        let capabilities = context.readiness.capabilities()
        guard capabilities.enabled else {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=remote_unlock_not_certified")
            return result(.denied, detail: "remote_unlock_not_certified")
        }
        guard context.isDirectPhoneControl,
              let manifestPeer = context.state?.manifest.phoneViewerNodeId,
              manifestPeer == credential.authority.peerNodeId else {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=untrusted_controller direct=\(context.isDirectPhoneControl) manifestPeer=\(context.state?.manifest.phoneViewerNodeId ?? "nil") credentialPeer=\(credential.authority.peerNodeId)")
            return result(.denied, detail: "untrusted_controller")
        }
        if let authorized = context.authorizedPeerNodeId,
           !authorized.isEmpty,
           authorized != credential.authority.peerNodeId {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=control_owned_by_other_viewer authorized=\(authorized) credentialPeer=\(credential.authority.peerNodeId)")
            return result(.denied, detail: "control_owned_by_other_viewer")
        }

        let validationNow = Date()
        guard let activeBinding = context.readiness.activeRemoteUnlockBinding(
            sessionId: credential.sessionId,
            peerNodeId: credential.authority.peerNodeId,
            now: validationNow
        ) else {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=session_mismatch")
            return result(.denied, detail: "session_mismatch")
        }
        let attestationRequirement = remoteUnlockCredentialAttestationRequirement(
            base: context.attestation,
            activeBinding: activeBinding
        )
        do {
            _ = try context.validator.validate(
                envelope: credential.authority,
                remoteUnlockCredential: credential,
                attestation: attestationRequirement,
                now: validationNow
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=\(validationDetail(for: error))")
            return result(.denied, detail: validationDetail(for: error))
        } catch {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=signature_failure")
            return result(.denied, detail: "signature_failure")
        }

        switch policy.validate(credential: credential, sessionId: credential.sessionId, now: validationNow) {
        case .allowed:
            break
        case .denied(let reason):
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=\(reason)")
            return result(.denied, detail: reason)
        }

        guard credential.recipientKeyId == capabilities.credentialRecipientKeyId else {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=recipient_key_mismatch")
            return result(.denied, detail: "recipient_key_mismatch")
        }

        let password: String
        do {
            let privateKey = try keyStore.copyPrivateKey()
            password = try RemoteUnlockCredentialEnvelopeCrypto.open(
                envelope: credential,
                recipientPrivateKey: privateKey
            )
        } catch {
            Self.debugTrace("remote_unlock_credential_failed requestID=\(credential.requestId) detail=credential_decryption_failed")
            return result(.failed, detail: "credential_decryption_failed")
        }

        let lockState = context.readiness.currentState(
            sessionId: credential.sessionId,
            controlOwnerViewerId: context.authorizedPeerNodeId
        ).lockState

        Self.log.info(
            "remote_unlock_credential_input_start requestID=\(credential.requestId, privacy: .public) sessionID=\(credential.sessionId, privacy: .public) peerNodeID=\(credential.authority.peerNodeId, privacy: .public) lockState=\(lockState.rawValue, privacy: .public)"
        )
        Self.debugTrace("remote_unlock_credential_input_start requestID=\(credential.requestId) sessionID=\(credential.sessionId) peerNodeID=\(credential.authority.peerNodeId) lockState=\(lockState.rawValue)")

        do {
            if lockState == .unlocked {
                _ = try inputController.type(text: password)
                _ = try inputController.key("Return")
            } else {
                let helper = RemoteAccessAgentClient()
                do {
                    try await helper.wakeDisplay()
                    Self.log.info(
                        "remote_unlock_display_wake_submitted requestID=\(credential.requestId, privacy: .public)"
                    )
                    Self.debugTrace("remote_unlock_display_wake_submitted requestID=\(credential.requestId)")
                } catch {
                    Self.log.error(
                        "remote_unlock_display_wake_failed requestID=\(credential.requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    Self.debugTrace("remote_unlock_display_wake_failed requestID=\(credential.requestId) error=\(String(describing: error))")
                }

                let backend = context.readiness.capabilities().activeBackend
                if backend == .openBurnBarVirtualHID {
                    Self.log.info(
                        "remote_unlock_virtual_hid_input_start requestID=\(credential.requestId, privacy: .public)"
                    )
                    Self.debugTrace("remote_unlock_virtual_hid_input_start requestID=\(credential.requestId)")
                    try await RemoteUnlockVirtualHIDClient(
                        sessionId: credential.sessionId,
                        peerNodeId: credential.authority.peerNodeId,
                        presentingEscrowDeviceId: activeBinding.viewerDeviceId,
                        requiredAttestationHashBlake3: activeBinding.attestationHashBlake3 ?? credential.authority.attestationHashBlake3
                    ).typeCredential(password)
                } else {
                    Self.log.info(
                        "remote_unlock_diagnostic_ard_start requestID=\(credential.requestId, privacy: .public) backend=\(backend.rawValue, privacy: .public)"
                    )
                    Self.debugTrace("remote_unlock_diagnostic_ard_start requestID=\(credential.requestId) backend=\(backend.rawValue)")
                    do {
                        try await AppleRemoteDesktopRFBClient().typeCredential(
                            .init(username: NSUserName(), password: password)
                        )
                        Self.log.info(
                            "remote_unlock_ard_input_submitted requestID=\(credential.requestId, privacy: .public)"
                        )
                        Self.debugTrace("remote_unlock_ard_input_submitted requestID=\(credential.requestId)")
                    } catch {
                        Self.log.error(
                            "remote_unlock_ard_input_failed requestID=\(credential.requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                        Self.debugTrace("remote_unlock_ard_input_failed requestID=\(credential.requestId) error=\(String(describing: error))")
                    }
                    Self.log.info(
                        "remote_unlock_privileged_worker_start requestID=\(credential.requestId, privacy: .public)"
                    )
                    Self.debugTrace("remote_unlock_privileged_worker_start requestID=\(credential.requestId)")
                    try await helper.typeCredential(password)
                }
            }
        } catch {
            let detail = remoteUnlockInputDetail(for: error)
            Self.log.error(
                "remote_unlock_credential_input_failed requestID=\(credential.requestId, privacy: .public) detail=\(detail, privacy: .public)"
            )
            Self.debugTrace("remote_unlock_credential_input_failed requestID=\(credential.requestId) detail=\(detail)")
            return result(.failed, detail: detail)
        }

        // Re-wake the physical display so it redraws the (now hopefully unlocked) desktop instead of
        // lingering on a stale, asleep lock screen. The credential path can unlock the session while
        // the panel stays dark, which looks like "nothing happened" and forces a manual Touch ID.
        try? await RemoteAccessAgentClient().wakeDisplay() // try?-ok(best-effort display rewake)

        try? await Task.sleep(nanoseconds: 700_000_000) // try?-ok(sleep cancellation only)
        let state = context.readiness.currentState(
            sessionId: credential.sessionId,
            controlOwnerViewerId: context.authorizedPeerNodeId
        )
        let unlocked = state.lockState == .unlocked
        Self.log.info(
            "remote_unlock_credential_input_finished requestID=\(credential.requestId, privacy: .public) status=\(unlocked ? "unlocked" : "accepted", privacy: .public) lockState=\(state.lockState.rawValue, privacy: .public)"
        )
        Self.debugTrace("remote_unlock_credential_input_finished requestID=\(credential.requestId) status=\(unlocked ? "unlocked" : "accepted") lockState=\(state.lockState.rawValue)")
        if unlocked, let keyMaterial = certificationKeyMaterial(requestId: credential.requestId) {
            context.readiness.recordCertification(
                fileVaultSSHSupported: state.capabilities.fileVaultSSHSupported,
                credentialRecipientKeyId: keyMaterial.keyId,
                credentialRecipientPublicKeyBase64: keyMaterial.publicKeyBase64
            )
        }
        return result(
            unlocked ? .unlocked : .accepted,
            detail: unlocked ? "unlocked" : "credential_submitted",
            lockState: state.lockState
        )
    }

    private func validationDetail(for error: PhoneControlAuthorityValidator.ValidationError) -> String {
        error.auditDetailToken
    }

    private func remoteUnlockCredentialAttestationRequirement(
        base: PhoneControlAttestationRequirement,
        activeBinding: MacRemoteUnlockReadinessService.ActiveRemoteUnlockBinding
    ) -> PhoneControlAttestationRequirement {
        if case .rejectUnboundHost = base {
            return base
        }
        guard let activeAttestation = activeBinding.attestationHashBlake3,
              activeAttestation.isEmpty == false else {
            return base
        }
        return .required(digest: activeAttestation)
    }

    /// Read (or create) the HPKE recipient key material that certification is recorded against.
    /// A keychain/key-material fault is security-relevant: we must never record a half-formed
    /// certification with missing/empty recipient key fields (that would advertise an
    /// undecryptable recipient and silently break later credential opens). On fault we fail
    /// closed — skip certification — and surface the loss instead of swallowing it.
    func certificationKeyMaterial(requestId: String) -> RemoteUnlockCredentialKeyMaterial? {
        do {
            return try keyStore.copyOrCreateKeyMaterial()
        } catch {
            let errorClass = String(describing: type(of: error))
            AppLogger.daemon.error(
                "remote_unlock_key_material_failed",
                metadata: [
                    "requestId": requestId,
                    "errorClass": errorClass
                ]
            )
            Self.debugTrace(
                "remote_unlock_key_material_failed requestID=\(requestId) errorClass=\(errorClass)"
            )
            return nil
        }
    }

    private func remoteUnlockInputDetail(for error: Error) -> String {
        if let inputError = error as? MacInputController.InputError {
            switch inputError {
            case .accessibilityNotTrusted: return "accessibility_not_trusted"
            case .displayBoundsViolation: return "display_bounds_violation"
            case .eventCreationFailed: return "event_creation_failed"
            case .dragEndpointMissing: return "drag_endpoint_missing"
            case .unknownKey: return "unknown_key"
            case .windowNotFound: return "window_not_found"
            }
        }
        if let daemonError = error as? RemoteAccessAgentClientError {
            switch daemonError {
            case .daemonRejected(let detail): return detail
            case .daemonUnavailable: return "remote_access_daemon_unavailable"
            case .readFailed: return "remote_access_daemon_read_failed"
            case .responseTooLarge: return "remote_access_daemon_response_too_large"
            case .serverUntrusted(let detail): return "remote_access_daemon_untrusted: \(detail)"
            case .socketPathTooLong: return "remote_access_daemon_socket_path_too_long"
            case .socketUnavailable: return "remote_access_daemon_socket_unavailable"
            case .timedOut: return "remote_access_daemon_timed_out"
            case .writeFailed: return "remote_access_daemon_write_failed"
            }
        }
        if let virtualHIDError = error as? RemoteUnlockVirtualHIDClientError {
            switch virtualHIDError {
            case .rejected(let detail): return detail
            case .unavailable: return "virtual_hid_bridge_unavailable"
            case .socketUnavailable: return "virtual_hid_bridge_socket_unavailable"
            case .timedOut: return "virtual_hid_bridge_timed_out"
            case .writeFailed: return "virtual_hid_bridge_write_failed"
            case .readFailed: return "virtual_hid_bridge_read_failed"
            case .responseTooLarge: return "virtual_hid_bridge_response_too_large"
            case .socketPathTooLong: return "virtual_hid_bridge_socket_path_too_long"
            }
        }
        return "credential_input_failed"
    }
}

// Internal (not private) so `@testable import OpenBurnBar` tests can pin the
// client-side server-trust gate with an impostor listener, mirroring
// `PrivilegedInputSocketClientTrustTests` in the core package.
struct RemoteAccessAgentClient: Sendable {
    typealias ServerCodeSignatureValidator = @Sendable (audit_token_t) throws -> Void

    private static let defaultSocketPath = "/var/run/openburnbar-remote-access-agent.sock"
    private static let maximumResponseBytes = 16 * 1024
    // Must exceed the helper's worker-exit backstop so the app never gives up while the helper is
    // still legitimately typing the password at the login window. The previous 8s was *shorter*
    // than the helper's own timeout budget, contributing to the "did not acknowledge" failures.
    // Mirrors RemoteAccessCredentialTimeoutPolicy.macClientSocketTimeoutSeconds. health/wakeDisplay
    // still return in milliseconds — this is only the maximum wait, not an added delay.
    private static let requestIOTimeoutSeconds: time_t = 20
    private var socketPath: String = Self.defaultSocketPath
    private let expectedServerUID: uid_t
    private let serverCodeSignatureValidator: ServerCodeSignatureValidator

    init(
        socketPath: String = Self.defaultSocketPath,
        expectedServerUID: uid_t = 0,
        serverCodeSignatureValidator: ServerCodeSignatureValidator? = nil
    ) {
        self.socketPath = socketPath
        // The remote-access agent is a root LaunchDaemon, so the server side of
        // this socket must always present uid 0 — a user-owned impostor bound
        // to the same path fails this check before any payload is written.
        self.expectedServerUID = expectedServerUID
        self.serverCodeSignatureValidator = serverCodeSignatureValidator
            ?? Self.defaultServerCodeSignatureValidator
    }

    /// Blocking socket send runs off the main actor: this is a `nonisolated`
    /// `async` method (the type is `Sendable`), so callers leave the main actor at
    /// the `await` (SE-0338).
    func typeCredential(_ password: String) async throws {
        try send(
            RemoteAccessAgentRequest(operation: "typeCredential", password: password)
        )
    }

    /// Runs off the main actor (`nonisolated` `async`, SE-0338).
    func wakeDisplay() async throws {
        try send(RemoteAccessAgentRequest(operation: "wakeDisplay", password: nil))
    }

    /// Synchronous send seam so tests can pin the server-trust gate directly
    /// (impostor listener receives zero bytes on trust failure).
    func sendForTesting(_ request: RemoteAccessAgentRequest) throws {
        try send(request)
    }

    private static let defaultServerCodeSignatureValidator: ServerCodeSignatureValidator = { token in
        // Pin the server to the remote-access agent's EXACT identifier, not the
        // shared privileged-input allowlist: `typeCredential` writes the macOS
        // login password, so another first-party root helper squatting this
        // socket path must not be able to receive it.
        try OpenBurnBarPrivilegedTrust.validateCodeSignature(
            ofAuditToken: token,
            requirementString: OpenBurnBarPrivilegedTrust.remoteAccessAgentDesignatedRequirement
        )
    }

    private func send(_ request: RemoteAccessAgentRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteAccessAgentClientError.socketUnavailable }
        defer { close(fd) }
        Self.configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw RemoteAccessAgentClientError.socketPathTooLong }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strncpy(destination, path, capacity - 1)
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw RemoteAccessAgentClientError.daemonUnavailable }

        // Authenticate the server BEFORE writing anything: `typeCredential`
        // requests carry the macOS login password, and a successful connect(2)
        // proves only that *something* is listening at the path. The agent is
        // a root LaunchDaemon, so the peer must be uid 0 AND satisfy the
        // first-party designated requirement — the same mutual-auth invariant
        // the privileged-input lane enforces (`PrivilegedInputXPCClient`).
        do {
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: fd,
                expectedUID: expectedServerUID,
                codeSignatureValidator: serverCodeSignatureValidator
            )
        } catch {
            throw RemoteAccessAgentClientError.serverUntrusted(String(describing: error))
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < payload.count {
                let written = Darwin.write(fd, base.advanced(by: offset), payload.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw RemoteAccessAgentClientError.timedOut }
                    throw RemoteAccessAgentClientError.writeFailed
                }
                offset += written
            }
        }
        _ = shutdown(fd, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw RemoteAccessAgentClientError.timedOut }
                throw RemoteAccessAgentClientError.readFailed
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumResponseBytes { throw RemoteAccessAgentClientError.responseTooLarge }
            if data.last == 0x0A { break }
        }

        let response = try JSONDecoder().decode(RemoteAccessAgentResponse.self, from: data)
        guard response.ok else {
            throw RemoteAccessAgentClientError.daemonRejected(response.error ?? "remote_access_daemon_rejected")
        }
    }

    private static func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }
}

private struct RemoteUnlockVirtualHIDClient: Sendable {
    var sessionId: String
    var peerNodeId: String
    var presentingEscrowDeviceId: String?
    var requiredAttestationHashBlake3: String?

    func typeCredential(_ password: String) async throws {
        do {
            let token = try await mintCredentialToken()
            let request = PrivilegedInputDispatchRequest(operation: "typeCredential", password: password)
            let envelope = PrivilegedInputDispatchEnvelope(
                request: request,
                capabilityToken: token,
                presentingEscrowDeviceId: presentingEscrowDeviceId,
                requiredAttestationHashBlake3: requiredAttestationHashBlake3
            )
            let response = try PrivilegedInputXPCClient().perform(envelope)
            guard response.ok else {
                throw RemoteUnlockVirtualHIDClientError.rejected(response.error ?? "privileged_input_rejected")
            }
        } catch let error as PrivilegedInputXPCClient.ClientError {
            throw RemoteUnlockVirtualHIDClientError(error)
        }
    }

    @MainActor
    private func mintCredentialToken() throws -> CapabilityToken {
        let scopeHash = SHA256.hash(data: Data("remote_unlock:\(sessionId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let token = try RemoteUnlockCapabilityTokenBroker.shared.mintInputToken(
            actionKind: "type_credential",
            scopeHash: scopeHash,
            attestationHashBlake3: requiredAttestationHashBlake3,
            boundEscrowDeviceId: presentingEscrowDeviceId,
            sessionId: sessionId,
            peerNodeId: peerNodeId
        ) else {
            throw RemoteUnlockVirtualHIDClientError.rejected("capability_token_missing")
        }
        return token
    }
}

private enum RemoteUnlockVirtualHIDClientError: Error {
    case rejected(String)
    case unavailable
    case socketUnavailable
    case timedOut
    case writeFailed
    case readFailed
    case responseTooLarge
    case socketPathTooLong

    init(_ error: RemoteAccessAgentClientError) {
        switch error {
        case .daemonRejected(let detail): self = .rejected(detail)
        case .daemonUnavailable: self = .unavailable
        case .socketUnavailable: self = .socketUnavailable
        case .timedOut: self = .timedOut
        case .writeFailed: self = .writeFailed
        case .readFailed: self = .readFailed
        case .responseTooLarge: self = .responseTooLarge
        case .serverUntrusted(let detail):
            // Server-side trust validation failed before any payload was
            // written — surface it verbatim for diagnostics, mirroring the
            // privileged-input lane's serverUntrusted handling.
            self = .rejected("remote_access_daemon_untrusted: \(detail)")
        case .socketPathTooLong: self = .socketPathTooLong
        }
    }

    init(_ error: PrivilegedInputXPCClient.ClientError) {
        switch error {
        case .connectionUnavailable, .remoteProxyUnavailable:
            self = .unavailable
        case .timedOut:
            self = .timedOut
        case .invalidResponse:
            self = .readFailed
        case .rejected(let detail):
            self = .rejected(detail)
        case .serverUntrusted(let detail): // cov:ignore -- shape passthrough
            // Peer code-signature trust validation failed — surface it as a
            // rejection so the trust failure reaches diagnostics verbatim.
            // Gated in PrivilegedInputSocketClientTrustTests (live impostor).
            self = .rejected("privileged_input_server_untrusted: \(detail)") // cov:ignore -- see above
        }
    }
}

struct RemoteAccessAgentRequest: Encodable, Sendable {
    var operation: String
    var password: String?
}

private struct RemoteAccessAgentResponse: Decodable {
    var ok: Bool
    var error: String?
}

enum RemoteAccessAgentClientError: Error {
    case daemonRejected(String)
    case daemonUnavailable
    case readFailed
    case responseTooLarge
    case serverUntrusted(String)
    case socketPathTooLong
    case socketUnavailable
    case timedOut
    case writeFailed
}
#endif
