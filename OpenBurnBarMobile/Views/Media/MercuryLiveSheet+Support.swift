import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import LocalAuthentication
import OSLog
import Security
import UIKit

// Phone-control setup message, mirror teardown triggers, remote-unlock saved-credential store, and the full-screen mirror viewer.
// Extracted from MercuryLiveSheet.swift (god-file decomposition) — same module, verbatim.

#if canImport(UIKit)
import UIKit
#endif
enum PhoneControlSetupMessage {
    static let trustedDeviceRequired = "Trust this iPhone for Mac control. If it is already trusted, confirm Computer Use is enabled for this account."

    static func message(for error: Error) -> String {
        if let gatewayError = error as? CloudGatewayError {
            switch gatewayError.classification {
            case .notAuthenticated:
                return "Sign in to control your Mac."
            case .networkUnavailable:
                return "You appear to be offline. Reconnect, then try Mac control again."
            case .appCheckBlocked:
                return "App Check blocked Mac control on this iPhone."
            case .permissionDenied:
                return trustedDeviceRequired
            default:
                return gatewayError.classification.recoveryHint
            }
        }
        if isFirestorePermissionDenied(error) {
            return trustedDeviceRequired
        }
        return error.localizedDescription
    }

    static func isFirestorePermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain,
           FirestoreErrorCode.Code(rawValue: ns.code) == .permissionDenied {
            return true
        }
        return ns.localizedDescription.localizedCaseInsensitiveContains("permission")
            || ns.localizedDescription.localizedCaseInsensitiveContains("insufficient")
    }
}

enum MercuryMirrorTeardownTrigger: Equatable {
    case explicitClose
    case signOut
    case sheetDisappear
    case viewerDisappear
    case sceneInactive

    var shouldSendMirrorStop: Bool {
        switch self {
        case .explicitClose, .signOut:
            return true
        case .sheetDisappear, .viewerDisappear, .sceneInactive:
            return false
        }
    }
}

enum RemoteUnlockCredentialStoreKey {
    static func make(
        state: HermesRealtimeRelayRemoteUnlockState?,
        phoneControlConnectionID: String?,
        mirrorConnectionID: String,
        mirrorRequestID: String?
    ) -> String? {
        if let recipientKey = nonEmpty(state?.capabilities.credentialRecipientKeyId) {
            return recipientKey
        }
        if let phoneConnectionID = nonEmpty(phoneControlConnectionID) {
            return phoneConnectionID
        }
        if let connectionID = nonEmpty(mirrorConnectionID) {
            return connectionID
        }
        return nonEmpty(mirrorRequestID)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RemoteUnlockCredentialSenderReusePolicy {
    static func shouldReuseExistingSender(
        phoneControlConnectionID: String?,
        currentConnectionID: String
    ) -> Bool {
        // Remote Unlock runs while the mirror is intentionally unstable: the Mac
        // may stop video, the viewer may reconnect, and moving the viewer can
        // churn the control stream. Rebuilding the signed sender is cheap and
        // prevents a stale point-and-click sender from reporting "sent" while
        // the credential frame never reaches the Mac.
        false
    }
}

// AUDIT(@unchecked Sendable): only non-Sendable stored property is UserDefaults
// (thread-safe, not yet Sendable-annotated). sendable-allowlist: foundation-sdk-shim
final class RemoteUnlockSavedCredentialStore: @unchecked Sendable {
    static let shared = RemoteUnlockSavedCredentialStore()

    private let service = "com.openburnbar.remote-unlock.saved-credential"
    private let defaultsPrefix = "remote_unlock.saved_credential_available."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasCredential(storeKey: String) -> Bool {
        defaults.bool(forKey: defaultsKey(storeKey: storeKey))
    }

    func save(_ password: String, storeKey: String) throws {
        guard let data = password.data(using: .utf8), !data.isEmpty else {
            throw StoreError.invalidCredential
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw StoreError.accessControlUnavailable
        }
        let query = baseQuery(storeKey: storeKey)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychainStatus(status) }
        defaults.set(true, forKey: defaultsKey(storeKey: storeKey))
    }

    func load(storeKey: String, reason: String) throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        var query = baseQuery(storeKey: storeKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            defaults.set(false, forKey: defaultsKey(storeKey: storeKey))
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.keychainStatus(status)
        }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw StoreError.invalidCredential
        }
        return password
    }

    func delete(storeKey: String) {
        SecItemDelete(baseQuery(storeKey: storeKey) as CFDictionary)
        defaults.set(false, forKey: defaultsKey(storeKey: storeKey))
    }

    private func baseQuery(storeKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(storeKey: storeKey)
        ]
    }

    private func account(storeKey: String) -> String {
        let trimmed = storeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown-mac" : trimmed
    }

    private func defaultsKey(storeKey: String) -> String {
        defaultsPrefix + account(storeKey: storeKey)
    }

    enum StoreError: Error {
        case accessControlUnavailable
        case invalidCredential
        case keychainStatus(OSStatus)
    }
}

struct MercuryMirrorViewerFullScreen: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    let controlStatus: ScreenSharePhoneControlStatus
    let controlInputEnabled: Bool
    let streamPhase: MediaControlStreamCoordinator.Phase
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let controlRoundTripMillis: Int?
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    let savedRemoteUnlockCredentialAvailable: Bool
    let remoteUnlockDiagnosticMessage: String?
    @Binding var remoteUnlockPasswordDraft: String
    let usePremiumSOTAUX: Bool
    let sendTapIntent: (Double, Double, Int) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: (Int) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let sendAgentContextTargetIntent: (Double, Double, String, String, String?) -> Void
    let pasteClipboardToMac: () -> Void
    let grabClipboardFromMac: () -> Void
    let sendRemoteUnlockCredential: (String) -> Void
    let saveRemoteUnlockCredential: (String) -> Void
    let sendSavedRemoteUnlockCredential: () -> Void
    let deleteSavedRemoteUnlockCredential: () -> Void
    let requestRemoteUnlockSetup: () -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void
    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus,
        controlInputEnabled: Bool,
        streamPhase: MediaControlStreamCoordinator.Phase,
        reconnectAttemptStartedAt: Date?,
        lastFailureReason: String?,
        lastLiveAt: Date?,
        controlRoundTripMillis: Int?,
        displays: [HermesRealtimeRelayDisplayDescriptor],
        selectedDisplayId: String?,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?,
        savedRemoteUnlockCredentialAvailable: Bool,
        remoteUnlockDiagnosticMessage: String?,
        remoteUnlockPasswordDraft: Binding<String>,
        usePremiumSOTAUX: Bool,
        sendTapIntent: @escaping (Double, Double, Int) -> Void,
        sendScrollIntent: @escaping (Double, Double, Double, Double, String?) -> Void,
        sendPointerMoveIntent: @escaping (Double, Double) -> Void,
        sendPointerClickIntent: @escaping (Int) -> Void,
        sendTextIntent: @escaping (String) -> Void,
        sendShortcutIntent: @escaping (String, [String]) -> Void,
        sendAgentContextTargetIntent: @escaping (Double, Double, String, String, String?) -> Void,
        pasteClipboardToMac: @escaping () -> Void,
        grabClipboardFromMac: @escaping () -> Void,
        sendRemoteUnlockCredential: @escaping (String) -> Void,
        saveRemoteUnlockCredential: @escaping (String) -> Void,
        sendSavedRemoteUnlockCredential: @escaping () -> Void,
        deleteSavedRemoteUnlockCredential: @escaping () -> Void,
        requestRemoteUnlockSetup: @escaping () -> Void,
        onSelectDisplay: @escaping (String) -> Void,
        onTrustControlDevice: @escaping () -> Void,
        onForceReconnect: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.controlInputEnabled = controlInputEnabled
        self.streamPhase = streamPhase
        self.reconnectAttemptStartedAt = reconnectAttemptStartedAt
        self.lastFailureReason = lastFailureReason
        self.lastLiveAt = lastLiveAt
        self.controlRoundTripMillis = controlRoundTripMillis
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.remoteUnlockState = remoteUnlockState
        self.savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable
        self.remoteUnlockDiagnosticMessage = remoteUnlockDiagnosticMessage
        self._remoteUnlockPasswordDraft = remoteUnlockPasswordDraft
        self.usePremiumSOTAUX = usePremiumSOTAUX
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendPointerMoveIntent = sendPointerMoveIntent
        self.sendPointerClickIntent = sendPointerClickIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
        self.sendAgentContextTargetIntent = sendAgentContextTargetIntent
        self.pasteClipboardToMac = pasteClipboardToMac
        self.grabClipboardFromMac = grabClipboardFromMac
        self.sendRemoteUnlockCredential = sendRemoteUnlockCredential
        self.saveRemoteUnlockCredential = saveRemoteUnlockCredential
        self.sendSavedRemoteUnlockCredential = sendSavedRemoteUnlockCredential
        self.deleteSavedRemoteUnlockCredential = deleteSavedRemoteUnlockCredential
        self.requestRemoteUnlockSetup = requestRemoteUnlockSetup
        self.onSelectDisplay = onSelectDisplay
        self.onTrustControlDevice = onTrustControlDevice
        self.onForceReconnect = onForceReconnect
        self.onRetryRequest = onRetryRequest
        self.onClose = onClose
    }

    var body: some View {
        ScreenShareViewerView(
            coordinator: coordinator,
            resetToken: resetToken,
            controlStatus: controlStatus,
            controlInputEnabled: controlInputEnabled,
            controlRoundTripMillis: controlRoundTripMillis,
            displays: displays,
            selectedDisplayId: selectedDisplayId,
            streamPhase: streamPhase,
            reconnectAttemptStartedAt: reconnectAttemptStartedAt,
            lastFailureReason: lastFailureReason,
            lastLiveAt: lastLiveAt,
            remoteUnlockState: remoteUnlockState,
            savedRemoteUnlockCredentialAvailable: savedRemoteUnlockCredentialAvailable,
            remoteUnlockDiagnosticMessage: remoteUnlockDiagnosticMessage,
            remoteUnlockPasswordDraft: $remoteUnlockPasswordDraft,
            usePremiumSOTAUX: usePremiumSOTAUX,
            onForceReconnect: onForceReconnect,
            onRetryRequest: onRetryRequest,
            sendTapIntent: sendTapIntent,
            sendScrollIntent: sendScrollIntent,
            sendPointerMoveIntent: sendPointerMoveIntent,
            sendPointerClickIntent: sendPointerClickIntent,
            sendTextIntent: sendTextIntent,
            sendShortcutIntent: sendShortcutIntent,
            sendAgentContextTargetIntent: sendAgentContextTargetIntent,
            pasteClipboardToMac: pasteClipboardToMac,
            grabClipboardFromMac: grabClipboardFromMac,
            sendRemoteUnlockCredential: sendRemoteUnlockCredential,
            saveRemoteUnlockCredential: saveRemoteUnlockCredential,
            sendSavedRemoteUnlockCredential: sendSavedRemoteUnlockCredential,
            deleteSavedRemoteUnlockCredential: deleteSavedRemoteUnlockCredential,
            requestRemoteUnlockSetup: requestRemoteUnlockSetup,
            onSelectDisplay: onSelectDisplay,
            onTrustControlDevice: onTrustControlDevice,
            onClose: onClose
        )
        .background(Color.black.ignoresSafeArea())
    }
}
