public struct LinuxIrohControllerCredentialContext: Sendable, Equatable {
    public let uid: String
    public let sessionGeneration: UInt64
    public let idToken: String
    public let appCheckToken: String
    public let deviceID: String

    public init(
        uid: String,
        sessionGeneration: UInt64,
        idToken: String,
        appCheckToken: String,
        deviceID: String
    ) {
        self.uid = uid
        self.sessionGeneration = sessionGeneration
        self.idToken = idToken
        self.appCheckToken = appCheckToken
        self.deviceID = deviceID
    }
}

public typealias LinuxIrohControllerCredentialProvider =
    @Sendable () async throws -> LinuxIrohControllerCredentialContext
