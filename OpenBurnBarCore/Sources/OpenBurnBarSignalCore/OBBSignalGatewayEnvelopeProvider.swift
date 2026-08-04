import Foundation

/// Type-erased official Signal v4 Gateway sealing surface shared by app targets.
/// Concrete transport modules return canonical JSON bytes so Swift concurrency
/// never crosses an untyped `[String: Any]` dictionary.
public protocol OBBSignalGatewayEnvelopeProvider: Sendable {
    func seal(
        plaintext: Data,
        uid: String,
        clientId: String,
        slotId: String
    ) async throws -> Data
}
