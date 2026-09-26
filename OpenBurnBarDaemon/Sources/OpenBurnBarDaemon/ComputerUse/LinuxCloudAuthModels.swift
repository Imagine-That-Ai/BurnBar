#if os(Linux)
import Foundation

struct LinuxCloudAuthStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case configurationRequired = "configuration_required"
        case signedOut = "signed_out"
        case authorizing
        case awaitingDeviceApproval = "awaiting_device_approval"
        case refreshing
        case ready
        case locked
        case error
    }

    let phase: Phase
    let operationID: String?
    let operationExpiresAt: Date?
    let hasStoredSession: Bool
    let reasonCode: String?

    init(
        phase: Phase,
        operationID: String? = nil,
        operationExpiresAt: Date? = nil,
        hasStoredSession: Bool,
        reasonCode: String? = nil
    ) {
        self.phase = phase
        self.operationID = operationID
        self.operationExpiresAt = operationExpiresAt
        self.hasStoredSession = hasStoredSession
        self.reasonCode = reasonCode
    }
}
#endif
