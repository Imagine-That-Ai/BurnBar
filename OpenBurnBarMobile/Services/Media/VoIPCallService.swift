import Foundation
#if canImport(PushKit)
import PushKit
#endif
#if canImport(CallKit)
import CallKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia

/// iOS PushKit + CallKit driver. Phase 5 wake-from-suspended path.
/// On first ring, CallKit's native UI handles lock-screen / suspended
/// presentation. When the iOS app is already foregrounded, the
/// `MercuryCallTransitionController` swaps in the Mercury sheet instead
/// (Decision 1 in `plans/2026-05-15-mercury-media-master-plan.md`).
@MainActor
final class VoIPCallService: NSObject {
    static let incomingCallNotification = Notification.Name("MediaCallIncomingNotification")
    static let endedCallNotification = Notification.Name("MediaCallEndedNotification")

    struct IncomingCall: Sendable, Equatable {
        let callID: UUID
        let connectionID: String
        let pairedDeviceID: String
        let displayName: String
        let isVideo: Bool
    }

    @Published private(set) var voipDeviceTokenHex: String?
    @Published private(set) var inFlightIncoming: IncomingCall?

    #if canImport(PushKit) && canImport(CallKit)
    private let pushRegistry: PKPushRegistry
    private let provider: CXProvider
    private let controller = CXCallController()
    #endif

    override init() {
        #if canImport(PushKit) && canImport(CallKit)
        let registry = PKPushRegistry(queue: .main)
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.supportedHandleTypes = [.generic]
        let provider = CXProvider(configuration: providerConfig)
        self.pushRegistry = registry
        self.provider = provider
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        provider.setDelegate(self, queue: nil)
        #else
        super.init()
        #endif
    }

    /// Phase 5: invoked by `MercuryIncomingSheet` Accept tap when the
    /// app is already foregrounded. Fulfills the CallKit answer action
    /// internally so CallKit + Mercury sheet stay coherent.
    func answerInFlightCall() {
        #if canImport(CallKit)
        guard let call = inFlightIncoming else { return }
        let action = CXAnswerCallAction(call: call.callID)
        let transaction = CXTransaction(action: action)
        controller.request(transaction) { _ in }
        #endif
    }

    func declineInFlightCall() {
        #if canImport(CallKit)
        guard let call = inFlightIncoming else { return }
        let action = CXEndCallAction(call: call.callID)
        let transaction = CXTransaction(action: action)
        controller.request(transaction) { _ in }
        #endif
    }
}

#if canImport(PushKit)
extension VoIPCallService: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        voipDeviceTokenHex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let dictionary = payload.dictionaryPayload
        let callID = (dictionary["callId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let connectionID = (dictionary["connectionId"] as? String) ?? "unknown"
        let pairedDeviceID = (dictionary["pairedDeviceId"] as? String) ?? "unknown"
        let displayName = (dictionary["displayName"] as? String) ?? "Mac call"
        let isVideo = (dictionary["isVideo"] as? Bool) ?? true

        #if canImport(CallKit)
        let update = CXCallUpdate()
        update.localizedCallerName = displayName
        update.hasVideo = isVideo
        update.remoteHandle = CXHandle(type: .generic, value: pairedDeviceID)
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            if error == nil {
                self?.inFlightIncoming = IncomingCall(
                    callID: callID,
                    connectionID: connectionID,
                    pairedDeviceID: pairedDeviceID,
                    displayName: displayName,
                    isVideo: isVideo
                )
            }
            completion()
        }
        #else
        completion()
        #endif
    }
}
#endif

#if canImport(CallKit)
extension VoIPCallService: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        inFlightIncoming = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = inFlightIncoming else {
            action.fulfill()
            return
        }
        // Decision 1: branch on app state.
        #if canImport(UIKit)
        let appState = UIApplication.shared.applicationState
        #else
        let appState: UIApplication.State = .background
        #endif
        action.fulfill()
        if appState == .active {
            NotificationCenter.default.post(name: VoIPCallService.incomingCallNotification, object: call)
        } else {
            // App will be foregrounded by CallKit; root view detects
            // `inFlightIncoming != nil` and routes directly to CallHUD.
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        let ended = inFlightIncoming
        inFlightIncoming = nil
        if let ended {
            NotificationCenter.default.post(name: VoIPCallService.endedCallNotification, object: ended)
        }
    }
}
#endif
