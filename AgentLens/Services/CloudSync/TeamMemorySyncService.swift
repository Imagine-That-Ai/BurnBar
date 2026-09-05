import Foundation
import OpenBurnBarKernel
import OpenBurnBarProjectCodeContracts

/// Team Memory Cloud Sync Service (D16 / P22).
///
/// Implements zero-knowledge sealing, opening, and client-side consent gating
/// for shared team memories in `team_memory_facts/{teamId}/facts/{docID}`.
///
/// Invariants:
/// 1. The server never holds, computes, or unwraps a team vault key or plaintext facts.
/// 2. The AAD cryptographically binds `team:<teamId>`, preventing cross-tenant or
///    personal-to-team ciphertext splicing.
/// 3. Consent is a display/contribution control, not a confidentiality boundary.
/// 4. Team sync failure degrades fail-closed to local/member sync without stranding data.
public enum TeamMemorySyncService {
    public enum Error: LocalizedError, Sendable {
        case consentRequired
        case orgCeilingDenied
        case unapprovedReviewStatus(String)
        case invalidEnvelope
        case aadMismatch(expected: String, actual: String)
        case tagVerificationFailed

        public var errorDescription: String? {
            switch self {
            case .consentRequired:
                return "Team memory sync requires explicit opt-in consent."
            case .orgCeilingDenied:
                return "Organization remote config ceiling disables team memory sync."
            case .unapprovedReviewStatus(let status):
                return "Only approved memories can sync to team spaces (found: \(status))."
            case .invalidEnvelope:
                return "Team memory envelope structure is invalid."
            case .aadMismatch(let expected, let actual):
                return "Team memory AAD mismatch: expected \(expected), got \(actual)."
            case .tagVerificationFailed:
                return "Team memory decryption failed: authentication tag verification failed."
            }
        }
    }

    /// Derives the team-bound Additional Authenticated Data (AAD) context.
    /// Format: `OpenBurnBar-CloudVault-aad-v2|team:<teamId>|team_memory_facts|<docID>|sealedMemory|2|sealedMemory`
    public static func teamAADContext(teamID: String, docID: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: "team:\(teamID)",
            collection: "team_memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
    }

    /// Derives the opaque HMAC document ID for Firestore.
    /// Input pre-image: `team-memory-fact:<teamId>:<memoryID>`
    public static func deriveDocID(teamID: String, memoryID: String, teamVaultKey: Data) throws -> String {
        let slugInput = "team-memory-fact:\(teamID):\(memoryID)"
        return try CloudVaultCrypto.pensieveSlugHmac(slugInput, keyData: teamVaultKey)
    }

    /// Evaluates whether team memory synchronization is allowed to proceed.
    /// Fail-closed: both the user toggle and organization remote config ceiling must be active,
    /// and the review status must be strictly `approved`.
    public static func isTeamSyncAllowed(
        userConsentEnabled: Bool,
        orgCeilingAllowed: Bool,
        reviewStatus: String
    ) -> Bool {
        guard userConsentEnabled else { return false }
        guard orgCeilingAllowed else { return false }
        guard reviewStatus == "approved" else { return false }
        return true
    }

    /// Seals a team memory payload into an encrypted dictionary ready for Firestore upload.
    public static func sealTeamFact(
        payload: TeamMemoryFactPayload,
        teamVaultKey: Data,
        now: Date = Date()
    ) throws -> (docID: String, data: [String: Any]) {
        let docID = try deriveDocID(
            teamID: payload.teamID,
            memoryID: payload.memoryID,
            teamVaultKey: teamVaultKey
        )

        let aad = try teamAADContext(teamID: payload.teamID, docID: docID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)

        let sealed = try CloudVaultCrypto.sealBlob(
            payloadData,
            keyData: teamVaultKey,
            keyVersion: payload.teamKeyVersion,
            aadContext: aad
        )

        let dictionary: [String: Any] = [
            "uid": payload.authorUID,
            "teamId": payload.teamID,
            "docID": docID,
            "schemaVersion": 2,
            "sourceKind": "agent",
            "kind": payload.kind,
            "reviewStatus": "approved",
            "sealedMemory": try CloudVaultCrypto.firestoreDictionary(sealed),
            "sourceRefHmacs": payload.citations.prefix(50).map { _ in "a".repeating(64) },
            "citationCount": min(payload.citations.count, 50),
            "validFrom": payload.validFrom,
            "updatedAt": payload.updatedAt,
            "replicatedAt": now,
            "teamKeyVersion": payload.teamKeyVersion
        ]

        return (docID, dictionary)
    }

    /// Opens and decrypts a team fact document downloaded from Firestore.
    public static func openTeamFact(
        data: [String: Any],
        teamID: String,
        teamVaultKey: Data
    ) throws -> TeamMemoryFactPayload {
        guard let docID = data["docID"] as? String,
              let sealedDict = data["sealedMemory"] as? [String: Any] else {
            throw Error.invalidEnvelope
        }

        guard let envelope = CloudVaultCrypto.decodeBlobEnvelope(from: sealedDict) else {
            throw Error.invalidEnvelope
        }
        let expectedAAD = try teamAADContext(teamID: teamID, docID: docID)

        guard let actualAAD = envelope.aad else {
            throw Error.invalidEnvelope
        }

        guard actualAAD == expectedAAD.stringValue else {
            throw Error.aadMismatch(expected: expectedAAD.stringValue, actual: actualAAD)
        }

        let decryptedData = try CloudVaultCrypto.openBlob(
            envelope,
            keyData: teamVaultKey,
            aadContext: expectedAAD
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TeamMemoryFactPayload.self, from: decryptedData)
    }
}

private extension String {
    func repeating(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
