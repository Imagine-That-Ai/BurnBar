#if !canImport(LibSignalClient)
// cov:ignore-start -- fallback envelope provider is compile-time excluded when LibSignalClient is linked, so no coverage-bearing lane can execute it; both methods unconditionally throw the OpenBurnBarSignalCoreAvailability fail-closed error, mirroring OpenBurnBarSignalCoreUnavailable.swift
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
// cov:ignore-end
#endif
