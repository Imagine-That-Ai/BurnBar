import OpenBurnBarEngine
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Privacy-safe attribution accepted from a gateway request. Only the exact
/// first-party Safari marker is retained, and its correlation value must be a
/// canonical UUID v4. Raw or malformed header values never enter route logs.
struct GatewayRequestAttribution: Hashable, Sendable {
    static let safariClientSource = "openburnbar-safari-extension"
    static let none = GatewayRequestAttribution(clientSource: nil, clientRequestCorrelationID: nil)

    let clientSource: String?
    let clientRequestCorrelationID: String?

    static func candidate(from headers: [String: String]) -> GatewayRequestAttribution? {
        guard let rawClientSource = headers["x-openburnbar-client"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            rawClientSource.caseInsensitiveCompare(safariClientSource) == .orderedSame,
            let correlationID = canonicalCorrelationID(
                headers["x-openburnbar-correlation-id"]
            ) else {
            return nil
        }
        return GatewayRequestAttribution(
            clientSource: safariClientSource,
            clientRequestCorrelationID: correlationID
        )
    }

    /// Strict parser retained for parser-only callers and tests. Production
    /// gateway requests must still pass through
    /// `SafariGatewayAttributionAuthority.resolve(headers:)`.
    static func from(headers: [String: String]) -> GatewayRequestAttribution {
        candidate(from: headers) ?? .none
    }

    static func canonicalCorrelationID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue.utf8.count == 36,
              let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame else {
            return nil
        }
        let canonical = uuid.uuidString.lowercased()
        let bytes = Array(canonical.utf8)
        guard bytes[14] == 0x34,
              [UInt8(0x38), 0x39, 0x61, 0x62].contains(bytes[19]) else {
            return nil
        }
        return canonical
    }
}

enum GatewayRequestAttributionResolution: Equatable, Sendable {
    case absent
    case accepted(GatewayRequestAttribution)
    case rejected

    var attribution: GatewayRequestAttribution {
        if case .accepted(let attribution) = self {
            return attribution
        }
        return .none
    }
}

/// Daemon-owned, memory-only authority for proving that a gateway request came
/// from an exact currently attached Safari extension session.
///
/// The general gateway bearer still authorizes provider access. This separate
/// capability authorizes only the privacy-safe `clientSource` attribution row.
/// Capability tokens are stored only as SHA-256 digests, expire quickly, and
/// may bind each request-correlation UUID exactly once.
public actor SafariGatewayAttributionAuthority {
    struct IssuedCapability: Equatable, Sendable {
        let token: String
        let expiresAt: Date
    }

    typealias SessionAttachmentValidator = @Sendable (
        _ clientID: BurnBarClientID,
        _ sessionID: BurnBarSessionID
    ) async -> Bool

    private struct SessionBinding: Hashable, Sendable {
        let clientID: BurnBarClientID
        let sessionID: BurnBarSessionID
    }

    private struct Record: Sendable {
        let clientID: BurnBarClientID
        let sessionID: BurnBarSessionID
        let generation: UUID
        let gatewayInstanceID: UUID
        var expiresAt: Date
        var consumedCorrelationIDs: Set<String>
        var resolvingCorrelationIDs: Set<String>
    }

    static let capabilityHeader = "x-openburnbar-attribution-capability"
    static let defaultLifetime: TimeInterval = 5 * 60
    static let maximumConsumedCorrelationIDs = 1_024

    private let gatewayInstanceID: UUID
    private let tokenKey: SymmetricKey
    private let lifetime: TimeInterval
    private let maximumCorrelationIDs: Int
    private let now: @Sendable () -> Date
    private let sessionAttachmentValidator: SessionAttachmentValidator
    private var recordsByDigest: [String: Record] = [:]
    private var currentGenerationByBinding: [SessionBinding: UUID] = [:]

    init(
        gatewayInstanceID: UUID = UUID(),
        lifetime: TimeInterval = defaultLifetime,
        maximumCorrelationIDs: Int = maximumConsumedCorrelationIDs,
        now: @escaping @Sendable () -> Date = Date.init,
        sessionAttachmentValidator: @escaping SessionAttachmentValidator = { _, _ in false }
    ) {
        self.gatewayInstanceID = gatewayInstanceID
        self.tokenKey = SymmetricKey(size: .bits256)
        self.lifetime = min(max(lifetime, 1), 15 * 60)
        self.maximumCorrelationIDs = max(1, maximumCorrelationIDs)
        self.now = now
        self.sessionAttachmentValidator = sessionAttachmentValidator
    }

    func issue(
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        forceRotation: Bool = false
    ) async -> IssuedCapability? {
        let issuedAt = now()
        removeExpired(now: issuedAt)
        let binding = SessionBinding(clientID: clientID, sessionID: sessionID)
        if !forceRotation,
           let (digest, existingRecord) = currentRecord(for: binding) {
            let isAttached = await sessionAttachmentValidator(
                clientID,
                sessionID
            )
            let validatedAt = now()
            guard isAttached,
                  currentGenerationByBinding[binding]
                    == existingRecord.generation,
                  var currentRecord = recordsByDigest[digest],
                  currentRecord.generation == existingRecord.generation,
                  currentRecord.expiresAt > validatedAt else {
                if let currentRecord = recordsByDigest[digest],
                   currentRecord.generation == existingRecord.generation {
                    invalidate(record: currentRecord, digest: digest)
                }
                return nil
            }
            // Routine authenticated bootstrap is a rolling lease renewal, not a
            // token rotation. Extend this exact live generation only after its
            // client/session attachment has been revalidated. Keeping the same
            // record preserves consumed and in-flight correlation reservations,
            // while the generation checks above prevent a concurrent rotation
            // from reviving or extending an obsolete capability.
            currentRecord.expiresAt = validatedAt.addingTimeInterval(lifetime)
            recordsByDigest[digest] = currentRecord
            return IssuedCapability(
                token: makeToken(
                    binding: binding,
                    generation: currentRecord.generation
                ),
                expiresAt: currentRecord.expiresAt
            )
        }
        let generation = UUID()

        // Actors are reentrant across the validator await. Claim the binding
        // and revoke its prior capability first so only the newest issuance
        // may commit after validation returns.
        let priorRecords = recordsByDigest.filter {
            $0.value.clientID == clientID && $0.value.sessionID == sessionID
        }
        for (digest, record) in priorRecords {
            invalidate(record: record, digest: digest)
        }
        currentGenerationByBinding[binding] = generation

        let isAttached = await sessionAttachmentValidator(clientID, sessionID)
        guard currentGenerationByBinding[binding] == generation else {
            return nil
        }
        guard isAttached else {
            currentGenerationByBinding.removeValue(forKey: binding)
            return nil
        }

        let token = makeToken(binding: binding, generation: generation)
        let expiresAt = now().addingTimeInterval(lifetime)
        recordsByDigest[Self.digest(token)] = Record(
            clientID: clientID,
            sessionID: sessionID,
            generation: generation,
            gatewayInstanceID: gatewayInstanceID,
            expiresAt: expiresAt,
            consumedCorrelationIDs: [],
            resolvingCorrelationIDs: []
        )
        return IssuedCapability(token: token, expiresAt: expiresAt)
    }

    func resolve(headers: [String: String]) async -> GatewayRequestAttributionResolution {
        let rawMarker = headers["x-openburnbar-client"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawMarker?.caseInsensitiveCompare(
            GatewayRequestAttribution.safariClientSource
        ) == .orderedSame else {
            return .absent
        }
        guard let candidate = GatewayRequestAttribution.candidate(from: headers),
              let rawToken = headers[Self.capabilityHeader]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isCanonicalToken(rawToken) else {
            return .rejected
        }

        let observedAt = now()
        removeExpired(now: observedAt)
        let digest = Self.digest(rawToken.lowercased())
        guard var record = recordsByDigest[digest],
              record.gatewayInstanceID == gatewayInstanceID,
              record.expiresAt > observedAt,
              let correlationID = candidate.clientRequestCorrelationID else {
            recordsByDigest.removeValue(forKey: digest)
            return .rejected
        }

        let binding = SessionBinding(
            clientID: record.clientID,
            sessionID: record.sessionID
        )
        guard currentGenerationByBinding[binding] == record.generation,
              record.consumedCorrelationIDs.contains(correlationID) == false else {
            invalidate(record: record, digest: digest)
            return .rejected
        }
        // A concurrent replay must lose without revoking the reservation held
        // by the first resolver, including when that reservation fills the
        // capability's correlation budget. Different correlations may validate
        // in parallel and will each commit only against this exact generation.
        guard record.resolvingCorrelationIDs.contains(correlationID) == false else {
            return .rejected
        }
        guard record.consumedCorrelationIDs.count
                + record.resolvingCorrelationIDs.count
                < maximumCorrelationIDs else {
            invalidate(record: record, digest: digest)
            return .rejected
        }
        record.resolvingCorrelationIDs.insert(correlationID)
        recordsByDigest[digest] = record

        let isAttached = await sessionAttachmentValidator(
            record.clientID,
            record.sessionID
        )
        let resolvedAt = now()
        guard isAttached,
              currentGenerationByBinding[binding] == record.generation,
              var currentRecord = recordsByDigest[digest],
              currentRecord.generation == record.generation,
              currentRecord.gatewayInstanceID == gatewayInstanceID,
              currentRecord.expiresAt > resolvedAt,
              currentRecord.resolvingCorrelationIDs.remove(correlationID) != nil,
              currentRecord.consumedCorrelationIDs.contains(correlationID) == false,
              currentRecord.consumedCorrelationIDs.count
                < maximumCorrelationIDs else {
            if let currentRecord = recordsByDigest[digest],
               currentRecord.generation == record.generation {
                invalidate(record: currentRecord, digest: digest)
            }
            return .rejected
        }
        currentRecord.consumedCorrelationIDs.insert(correlationID)
        recordsByDigest[digest] = currentRecord
        return .accepted(candidate)
    }

    private func removeExpired(now: Date) {
        let expired = recordsByDigest.filter { $0.value.expiresAt <= now }
        for (digest, record) in expired {
            invalidate(record: record, digest: digest)
        }
    }

    private func invalidate(record: Record, digest: String) {
        recordsByDigest.removeValue(forKey: digest)
        let binding = SessionBinding(
            clientID: record.clientID,
            sessionID: record.sessionID
        )
        if currentGenerationByBinding[binding] == record.generation {
            currentGenerationByBinding.removeValue(forKey: binding)
        }
    }

    private func currentRecord(
        for binding: SessionBinding
    ) -> (digest: String, record: Record)? {
        guard let generation = currentGenerationByBinding[binding] else {
            return nil
        }
        return recordsByDigest.first {
            $0.value.clientID == binding.clientID
                && $0.value.sessionID == binding.sessionID
                && $0.value.generation == generation
        }
    }

    private func makeToken(
        binding: SessionBinding,
        generation: UUID
    ) -> String {
        let input = [
            "openburnbar-safari-attribution-v1",
            binding.clientID.rawValue,
            binding.sessionID.rawValue,
            generation.uuidString.lowercased(),
            gatewayInstanceID.uuidString.lowercased()
        ].joined(separator: "\u{0}")
        return HMAC<SHA256>.authenticationCode(
            for: Data(input.utf8),
            using: tokenKey
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private static func isCanonicalToken(_ value: String) -> Bool {
        guard value.utf8.count == 64, value == value.lowercased() else {
            return false
        }
        return value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
