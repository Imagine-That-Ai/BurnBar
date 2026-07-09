import Foundation

public struct BurnBarClientAttachRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let clientName: String
    public let supportedProtocolVersions: [Int]

    public init(
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        clientName: String,
        supportedProtocolVersions: [Int]
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.clientName = clientName
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

public struct BurnBarClientAttachResponse: Codable, Hashable, Sendable {
    public let attachedClientID: BurnBarClientID
    public let negotiatedProtocolVersion: Int?

    public init(attachedClientID: BurnBarClientID, negotiatedProtocolVersion: Int?) {
        self.attachedClientID = attachedClientID
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
    }
}

public struct BurnBarClientClaimControlRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        self.clientID = clientID
        self.sessionID = sessionID
    }
}

public struct BurnBarClientDetachRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        self.clientID = clientID
        self.sessionID = sessionID
    }
}

public struct BurnBarClientArbitrationSnapshot: Codable, Hashable, Sendable {
    public let activeClientID: BurnBarClientID?
    public let attachedClientIDs: [BurnBarClientID]
    public let reason: String?

    public init(activeClientID: BurnBarClientID?, attachedClientIDs: [BurnBarClientID], reason: String? = nil) {
        self.activeClientID = activeClientID
        self.attachedClientIDs = attachedClientIDs
        self.reason = reason
    }
}
