#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Darwin
import Foundation
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

public final class GeneralRemoteClipboardPasteboard: RemoteClipboardPasteboard, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func readString() -> String? {
        pasteboard.string(forType: .string)
    }

    public func writeString(_ text: String) throws {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

        public init(
            activeSessionId: ComputerUseSessionID?,
            state: ComputerUseSessionState?,
            configuration: ComputerUseSessionCoordinator.Configuration,
            auditLogger: ComputerUseAuditLogger?,
            scopeRules: [ComputerUseScopeRule],
            validator: PhoneControlAuthorityValidator,
            isDirectPhoneControl: Bool,
            attestation: PhoneControlAttestationRequirement = .none
        ) {
            self.activeSessionId = activeSessionId
            self.state = state
            self.configuration = configuration
            self.auditLogger = auditLogger
            self.scopeRules = scopeRules
            self.validator = validator
            self.isDirectPhoneControl = isDirectPhoneControl
            self.attestation = attestation
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
                now: Date()
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
        case .allowed:
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
        NSLog("OpenBurnBarMercury \(message)")
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
    private let keyStore: RemoteUnlockCredentialKeyStore
    private let policy: RemoteUnlockPolicy

    init(
        inputController: MacInputController = MacInputController(),
        keyStore: RemoteUnlockCredentialKeyStore = .shared,
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
        do {
            _ = try context.validator.validate(
                envelope: credential.authority,
                remoteUnlockCredential: credential,
                attestation: context.attestation,
                now: validationNow
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=\(validationDetail(for: error))")
            return result(.denied, detail: validationDetail(for: error))
        } catch {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=signature_failure")
            return result(.denied, detail: "signature_failure")
        }

        guard context.readiness.isRemoteUnlockSessionActive(
            sessionId: credential.sessionId,
            peerNodeId: credential.authority.peerNodeId,
            now: validationNow
        ) else {
            Self.debugTrace("remote_unlock_credential_denied requestID=\(credential.requestId) detail=session_mismatch")
            return result(.denied, detail: "session_mismatch")
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
                    try await RemoteUnlockVirtualHIDClient().typeCredential(password)
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
        try? await RemoteAccessAgentClient().wakeDisplay()

        try? await Task.sleep(nanoseconds: 700_000_000)
        let state = context.readiness.currentState(
            sessionId: credential.sessionId,
            controlOwnerViewerId: context.authorizedPeerNodeId
        )
        let unlocked = state.lockState == .unlocked
        Self.log.info(
            "remote_unlock_credential_input_finished requestID=\(credential.requestId, privacy: .public) status=\(unlocked ? "unlocked" : "accepted", privacy: .public) lockState=\(state.lockState.rawValue, privacy: .public)"
        )
        Self.debugTrace("remote_unlock_credential_input_finished requestID=\(credential.requestId) status=\(unlocked ? "unlocked" : "accepted") lockState=\(state.lockState.rawValue)")
        if unlocked, let keyMaterial = try? keyStore.copyOrCreateKeyMaterial() {
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

private struct RemoteAccessAgentClient: Sendable {
    private static let defaultSocketPath = "/var/run/openburnbar-remote-access-agent.sock"
    private static let maximumResponseBytes = 16 * 1024
    // Must exceed the helper's worker-exit backstop so the app never gives up while the helper is
    // still legitimately typing the password at the login window. The previous 8s was *shorter*
    // than the helper's own timeout budget, contributing to the "did not acknowledge" failures.
    // Mirrors RemoteAccessCredentialTimeoutPolicy.macClientSocketTimeoutSeconds. health/wakeDisplay
    // still return in milliseconds — this is only the maximum wait, not an added delay.
    private static let requestIOTimeoutSeconds: time_t = 20
    private var socketPath: String = Self.defaultSocketPath

    init(socketPath: String = Self.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func typeCredential(_ password: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try send(
                RemoteAccessAgentRequest(operation: "typeCredential", password: password)
            )
        }.value
    }

    func wakeDisplay() async throws {
        try await Task.detached(priority: .userInitiated) {
            try send(RemoteAccessAgentRequest(operation: "wakeDisplay", password: nil))
        }.value
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
    private static let socketPath = RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath

    func typeCredential(_ password: String) async throws {
        do {
            try await RemoteAccessAgentClient(socketPath: Self.socketPath).typeCredential(password)
        } catch let error as RemoteAccessAgentClientError {
            throw RemoteUnlockVirtualHIDClientError(error)
        }
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
        case .socketPathTooLong: self = .socketPathTooLong
        }
    }
}

private struct RemoteAccessAgentRequest: Encodable, Sendable {
    var operation: String
    var password: String?
}

private struct RemoteAccessAgentResponse: Decodable {
    var ok: Bool
    var error: String?
}

private enum RemoteAccessAgentClientError: Error {
    case daemonRejected(String)
    case daemonUnavailable
    case readFailed
    case responseTooLarge
    case socketPathTooLong
    case socketUnavailable
    case timedOut
    case writeFailed
}
#endif
