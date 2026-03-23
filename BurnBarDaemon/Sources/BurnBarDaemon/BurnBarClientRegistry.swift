import BurnBarCore
import Foundation

public enum BurnBarClientRegistryError: Error, LocalizedError {
    case clientNotAttached(BurnBarClientID)
    case controllerRequired(BurnBarClientID)
    case sessionMismatch(expected: BurnBarSessionID, actual: BurnBarSessionID)

    public var errorDescription: String? {
        switch self {
        case .clientNotAttached(let clientID):
            return "Client '\(clientID.rawValue)' is not attached to the BurnBar daemon."
        case .controllerRequired(let clientID):
            return "Client '\(clientID.rawValue)' is attached as an observer and cannot control runs."
        case .sessionMismatch(let expected, let actual):
            return "Client session mismatch. Expected '\(expected.rawValue)', received '\(actual.rawValue)'."
        }
    }
}

private struct BurnBarAttachedClient: Sendable {
    let clientID: BurnBarClientID
    var sessionID: BurnBarSessionID
    var clientName: String
    var supportedProtocolVersions: [Int]
    let attachedAt: Date
    var lastSeenAt: Date
}

public actor BurnBarClientRegistry {
    private let logger: BurnBarDaemonLogger
    private var attachedClients: [BurnBarClientID: BurnBarAttachedClient] = [:]
    private var attachmentOrder: [BurnBarClientID] = []
    private var activeClientID: BurnBarClientID?

    public init(logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "client-registry")) {
        self.logger = logger
    }

    public func attach(_ request: BurnBarClientAttachRequest) -> (BurnBarClientAttachResponse, BurnBarClientArbitrationSnapshot) {
        let now = Date()
        let negotiatedProtocolVersion = BurnBarProtocolVersion.negotiate(with: request.supportedProtocolVersions)
        let reason: String

        if var existingClient = attachedClients[request.clientID] {
            existingClient.sessionID = request.sessionID
            existingClient.clientName = request.clientName
            existingClient.supportedProtocolVersions = request.supportedProtocolVersions
            existingClient.lastSeenAt = now
            attachedClients[request.clientID] = existingClient

            if activeClientID == request.clientID {
                reason = "controller_reconnected"
            } else if activeClientID == nil {
                activeClientID = request.clientID
                reason = "reconnected_and_promoted_to_controller"
            } else {
                reason = "observer_reconnected_controller_retained"
            }
        } else {
            attachedClients[request.clientID] = BurnBarAttachedClient(
                clientID: request.clientID,
                sessionID: request.sessionID,
                clientName: request.clientName,
                supportedProtocolVersions: request.supportedProtocolVersions,
                attachedAt: now,
                lastSeenAt: now
            )
            attachmentOrder.append(request.clientID)

            if activeClientID == nil {
                activeClientID = request.clientID
                reason = "first_controller_attached"
            } else {
                reason = "observer_attached_controller_retained"
            }
        }

        let response = BurnBarClientAttachResponse(
            attachedClientID: request.clientID,
            negotiatedProtocolVersion: negotiatedProtocolVersion
        )
        let arbitration = arbitrationSnapshot(reason: reason)

        logger.notice(
            "client_attached",
            metadata: [
                "client_id": request.clientID.rawValue,
                "session_id": request.sessionID.rawValue,
                "reason": reason
            ]
        )

        return (response, arbitration)
    }

    public func detach(_ request: BurnBarClientDetachRequest) throws -> BurnBarClientArbitrationSnapshot {
        guard let attachedClient = attachedClients[request.clientID] else {
            throw BurnBarClientRegistryError.clientNotAttached(request.clientID)
        }
        guard attachedClient.sessionID == request.sessionID else {
            throw BurnBarClientRegistryError.sessionMismatch(expected: attachedClient.sessionID, actual: request.sessionID)
        }

        attachedClients.removeValue(forKey: request.clientID)
        attachmentOrder.removeAll { $0 == request.clientID }

        let reason: String
        if activeClientID == request.clientID {
            activeClientID = attachmentOrder.first
            reason = activeClientID == nil
                ? "controller_detached_no_clients_remaining"
                : "controller_detached_observer_promoted"
        } else {
            reason = "observer_detached"
        }

        let arbitration = arbitrationSnapshot(reason: reason)

        logger.notice(
            "client_detached",
            metadata: [
                "client_id": request.clientID.rawValue,
                "reason": reason
            ]
        )

        return arbitration
    }

    public func claimControl(_ request: BurnBarClientClaimControlRequest) throws -> BurnBarClientArbitrationSnapshot {
        guard let attachedClient = attachedClients[request.clientID] else {
            throw BurnBarClientRegistryError.clientNotAttached(request.clientID)
        }
        guard attachedClient.sessionID == request.sessionID else {
            throw BurnBarClientRegistryError.sessionMismatch(expected: attachedClient.sessionID, actual: request.sessionID)
        }

        let reason: String
        if activeClientID == request.clientID {
            reason = "controller_already_active"
        } else {
            activeClientID = request.clientID
            reason = "controller_transferred_to_requesting_client"
        }

        let arbitration = arbitrationSnapshot(reason: reason)
        logger.notice(
            "client_control_claimed",
            metadata: [
                "client_id": request.clientID.rawValue,
                "reason": reason
            ]
        )

        return arbitration
    }

    public func arbitration() -> BurnBarClientArbitrationSnapshot {
        arbitrationSnapshot(reason: nil)
    }

    public func requireAttached(_ clientID: BurnBarClientID) throws {
        guard attachedClients[clientID] != nil else {
            throw BurnBarClientRegistryError.clientNotAttached(clientID)
        }
    }

    public func requireAttached(_ clientID: BurnBarClientID, sessionID: BurnBarSessionID) throws {
        guard let attachedClient = attachedClients[clientID] else {
            throw BurnBarClientRegistryError.clientNotAttached(clientID)
        }
        guard attachedClient.sessionID == sessionID else {
            throw BurnBarClientRegistryError.sessionMismatch(expected: attachedClient.sessionID, actual: sessionID)
        }
    }

    public func requireController(_ clientID: BurnBarClientID) throws {
        try requireAttached(clientID)
        guard activeClientID == clientID else {
            throw BurnBarClientRegistryError.controllerRequired(clientID)
        }
    }

    public func isAttached(_ clientID: BurnBarClientID) -> Bool {
        attachedClients[clientID] != nil
    }

    public func isController(_ clientID: BurnBarClientID) -> Bool {
        activeClientID == clientID
    }

    public func sessionID(for clientID: BurnBarClientID) -> BurnBarSessionID? {
        attachedClients[clientID]?.sessionID
    }

    private func arbitrationSnapshot(reason: String?) -> BurnBarClientArbitrationSnapshot {
        BurnBarClientArbitrationSnapshot(
            activeClientID: activeClientID,
            attachedClientIDs: attachmentOrder,
            reason: reason
        )
    }
}
