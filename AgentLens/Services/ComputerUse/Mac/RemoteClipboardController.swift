#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Foundation
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

        public init(
            activeSessionId: ComputerUseSessionID?,
            state: ComputerUseSessionState?,
            configuration: ComputerUseSessionCoordinator.Configuration,
            auditLogger: ComputerUseAuditLogger?,
            scopeRules: [ComputerUseScopeRule],
            validator: PhoneControlAuthorityValidator,
            isDirectPhoneControl: Bool
        ) {
            self.activeSessionId = activeSessionId
            self.state = state
            self.configuration = configuration
            self.auditLogger = auditLogger
            self.scopeRules = scopeRules
            self.validator = validator
            self.isDirectPhoneControl = isDirectPhoneControl
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
            originatedFromPhone: true
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
        switch error {
        case .missingPeerPubKey, .signatureFailed, .intentHashMismatch:
            return "signature_failure"
        case .counterReplay:
            return "counter_replay"
        case .staleTimestamp:
            return "stale_timestamp"
        }
    }
}

@MainActor
final class RemoteUnlockCredentialController {
    struct RuntimeContext {
        var validator: PhoneControlAuthorityValidator
        var activeSessionId: ComputerUseSessionID?
        var state: ComputerUseSessionState?
        var isDirectPhoneControl: Bool
        var authorizedPeerNodeId: String?
        var readiness: MacRemoteUnlockReadinessService

        @MainActor init(
            validator: PhoneControlAuthorityValidator,
            activeSessionId: ComputerUseSessionID?,
            state: ComputerUseSessionState?,
            isDirectPhoneControl: Bool,
            authorizedPeerNodeId: String?,
            readiness: MacRemoteUnlockReadinessService = .shared
        ) {
            self.validator = validator
            self.activeSessionId = activeSessionId
            self.state = state
            self.isDirectPhoneControl = isDirectPhoneControl
            self.authorizedPeerNodeId = authorizedPeerNodeId
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
            return result(.denied, detail: "remote_unlock_not_certified")
        }
        guard context.isDirectPhoneControl,
              let manifestPeer = context.state?.manifest.phoneViewerNodeId,
              manifestPeer == credential.authority.peerNodeId else {
            return result(.denied, detail: "untrusted_controller")
        }
        if let authorized = context.authorizedPeerNodeId,
           !authorized.isEmpty,
           authorized != credential.authority.peerNodeId {
            return result(.denied, detail: "control_owned_by_other_viewer")
        }

        do {
            _ = try context.validator.validate(
                envelope: credential.authority,
                remoteUnlockCredential: credential,
                now: Date()
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            return result(.denied, detail: validationDetail(for: error))
        } catch {
            return result(.denied, detail: "signature_failure")
        }

        switch policy.validate(credential: credential, sessionId: context.activeSessionId?.rawValue ?? "", now: Date()) {
        case .allowed:
            break
        case .denied(let reason):
            return result(.denied, detail: reason)
        }

        guard credential.recipientKeyId == capabilities.credentialRecipientKeyId else {
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
            return result(.failed, detail: "credential_decryption_failed")
        }

        do {
            _ = try inputController.type(text: password)
            _ = try inputController.key("Return")
        } catch {
            return result(.failed, detail: remoteUnlockInputDetail(for: error))
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        let state = context.readiness.currentState(
            sessionId: credential.sessionId,
            controlOwnerViewerId: context.authorizedPeerNodeId
        )
        let unlocked = state.lockState == .unlocked
        return result(
            unlocked ? .unlocked : .accepted,
            detail: unlocked ? "unlocked" : "credential_submitted",
            lockState: state.lockState
        )
    }

    private func validationDetail(for error: PhoneControlAuthorityValidator.ValidationError) -> String {
        switch error {
        case .missingPeerPubKey, .signatureFailed, .intentHashMismatch:
            return "signature_failure"
        case .counterReplay:
            return "counter_replay"
        case .staleTimestamp:
            return "stale_timestamp"
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
            }
        }
        return "credential_input_failed"
    }
}
#endif
