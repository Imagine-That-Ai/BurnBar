import Foundation
#if canImport(FirebaseFunctions)
import FirebaseFunctions
#endif

/// Mac-side trigger for the iOS PushKit wake. Calls the
/// `triggerVoIPCall` callable Cloud Function which verifies the calling
/// Mac's `hosted_media_sync` entitlement (Decision 2) and forwards the
/// APNs VoIP push to the paired iPhone.
@MainActor
final class VoIPCallTrigger {
    enum Failure: Error, LocalizedError {
        case functionsUnavailable
        case missingDeviceToken
        case callableFailed(String)

        var errorDescription: String? {
            switch self {
            case .functionsUnavailable: return "Firebase Functions unavailable on this build."
            case .missingDeviceToken: return "No PushKit device token cached for the paired iPhone."
            case .callableFailed(let m): return "triggerVoIPCall failed: \(m)"
            }
        }
    }

    struct Payload: Sendable, Equatable {
        let callID: String
        let connectionID: String
        let pairedDeviceID: String
        let displayName: String
        let isVideo: Bool
    }

    func trigger(_ payload: Payload, voipDeviceTokenHex: String) async throws {
        #if canImport(FirebaseFunctions)
        let callable = Functions.functions().httpsCallable("triggerVoIPCall")
        let body: [String: Any] = [
            "callId": payload.callID,
            "connectionId": payload.connectionID,
            "pairedDeviceId": payload.pairedDeviceID,
            "displayName": payload.displayName,
            "isVideo": payload.isVideo,
            "voipDeviceToken": voipDeviceTokenHex
        ]
        do {
            _ = try await callable.call(body)
        } catch {
            throw Failure.callableFailed(error.localizedDescription)
        }
        #else
        throw Failure.functionsUnavailable
        #endif
    }
}
