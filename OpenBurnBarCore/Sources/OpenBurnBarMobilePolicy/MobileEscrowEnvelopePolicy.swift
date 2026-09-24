import Foundation

/// Escrow import failures. Physical-device transfer stays a blocked ledger row
/// — this classifier is unit/scrutiny only.
public enum MobileEscrowImportFailure: String, Sendable, Equatable, CaseIterable {
    case wrongDevice = "wrong-device"
    case expiredGrant = "expired-grant"
    case revokedGrant = "revoked-grant"
    case missingKey = "missing-key"
    case malformedEnvelope = "malformed-envelope"

    public var userVisibleLabel: String {
        switch self {
        case .wrongDevice: return "This envelope is for a different device"
        case .expiredGrant: return "The transfer grant has expired"
        case .revokedGrant: return "The transfer grant was revoked"
        case .missingKey: return "This device is missing the escrow key"
        case .malformedEnvelope: return "The envelope is malformed"
        }
    }
}

public enum MobileEscrowEnvelopePolicy {
    public static func classify(
        targetDeviceId: String?,
        currentDeviceId: String?,
        grantStatus: String?,
        grantExpiresAtMs: Int64?,
        nowMs: Int64,
        hasPrivateKey: Bool,
        envelopeWellFormed: Bool
    ) -> MobileEscrowImportFailure? {
        guard envelopeWellFormed else { return .malformedEnvelope }
        guard hasPrivateKey else { return .missingKey }
        let target = targetDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let current = currentDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty, !current.isEmpty, target == current else {
            return .wrongDevice
        }
        let status = (grantStatus ?? "").lowercased()
        if status == "revoked" { return .revokedGrant }
        // Grants are allowed to omit expiry — firestore.rules does not persist
        // expiresAtMillis today. Only a present, elapsed timestamp expires.
        if let expiry = grantExpiresAtMs, expiry > 0, expiry <= nowMs {
            return .expiredGrant
        }
        return nil
    }
}
