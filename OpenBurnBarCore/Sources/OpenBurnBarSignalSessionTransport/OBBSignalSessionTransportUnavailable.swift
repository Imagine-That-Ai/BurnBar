#if !canImport(LibSignalClient)
import Foundation
import OpenBurnBarSignalCore

public enum OpenBurnBarSignalSessionTransportAvailability: Sendable {
    public static let isLibSignalBacked = false
    public static let unavailableReason = OpenBurnBarSignalCoreAvailability.unavailableReason
}

public struct OBBSignalSessionGatewayEnvelopeProvider: OBBSignalGatewayEnvelopeProvider {
    public init() {}

    public func seal(
        plaintext: Data,
        uid: String,
        clientId: String,
        slotId: String
    ) async throws -> Data {
        throw NSError(
            domain: "OpenBurnBarSignalSessionTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: OpenBurnBarSignalCoreAvailability.unavailableReason]
        )
    }

    public func open(
        envelopeData: Data,
        uid: String,
        clientId: String,
        slotId: String
    ) async throws -> Data {
        throw NSError(
            domain: "OpenBurnBarSignalSessionTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: OpenBurnBarSignalCoreAvailability.unavailableReason]
        )
    }
}
#endif
