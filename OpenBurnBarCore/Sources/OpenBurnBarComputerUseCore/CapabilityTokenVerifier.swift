import Foundation
import CryptoKit

public enum CapabilityTokenVerificationFailure: String, Codable, Sendable, Equatable, Error {
    case missingToken = "capability_token_missing"
    case missingSignature = "capability_token_missing_signature"
    case signatureInvalid = "capability_token_signature_invalid"
    case expired = "capability_token_expired"
    case domainMismatch = "capability_token_domain_mismatch"
    case nonceReplay = "capability_token_nonce_replay"
    case actionNotAllowed = "capability_token_action_not_allowed"
    case actionBudgetExhausted = "capability_token_action_budget_exhausted"
    case attestationMismatch = "capability_token_attestation_mismatch"
    case escrowDeviceMismatch = "capability_token_escrow_device_mismatch"
    case issuerKeyUnavailable = "capability_token_issuer_key_unavailable"
    case issuerRevoked = "capability_token_issuer_revoked"
}

/// Tracks consumed single-use nonces for offline leaf verification.
public protocol CapabilityTokenNonceStore: Sendable {
    func hasConsumed(nonce: String, domain: CapabilityToken.Domain) -> Bool
    func consume(nonce: String, domain: CapabilityToken.Domain) throws
}

/// In-memory nonce store for unit tests and ephemeral coordinators.
public final class InMemoryCapabilityTokenNonceStore: CapabilityTokenNonceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: Set<String> = []

    public init() {}

    private func key(nonce: String, domain: CapabilityToken.Domain) -> String {
        "\(domain.rawValue):\(nonce)"
    }

    public func hasConsumed(nonce: String, domain: CapabilityToken.Domain) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumed.contains(key(nonce: nonce, domain: domain))
    }

    public func consume(nonce: String, domain: CapabilityToken.Domain) throws {
        lock.lock()
        defer { lock.unlock() }
        let entry = key(nonce: nonce, domain: domain)
        guard !consumed.contains(entry) else {
            throw CapabilityTokenVerificationFailure.nonceReplay
        }
        consumed.insert(entry)
    }
}

/// File-backed nonce ledger shared by the Virtual HID bridge (offline, no network).
public final class FileCapabilityTokenNonceStore: CapabilityTokenNonceStore, @unchecked Sendable {
    public struct Ledger: Codable, Sendable, Equatable {
        public var consumed: [String]
        public init(consumed: [String] = []) {
            self.consumed = consumed
        }
    }

    private let path: String
    private let lock = NSLock()
    private let maximumEntries = 10_000

    public init(path: String = RemoteUnlockSetupProbe.capabilityTokenNonceLedgerPath) {
        self.path = path
    }

    public func hasConsumed(nonce: String, domain: CapabilityToken.Domain) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().consumed.contains(entryKey(nonce: nonce, domain: domain))
    }

    public func consume(nonce: String, domain: CapabilityToken.Domain) throws {
        lock.lock()
        defer { lock.unlock() }
        var ledger = loadLocked()
        let entry = entryKey(nonce: nonce, domain: domain)
        guard !ledger.consumed.contains(entry) else {
            throw CapabilityTokenVerificationFailure.nonceReplay
        }
        ledger.consumed.append(entry)
        if ledger.consumed.count > maximumEntries {
            ledger.consumed = Array(ledger.consumed.suffix(maximumEntries / 2))
        }
        try persistLocked(ledger)
    }

    private func entryKey(nonce: String, domain: CapabilityToken.Domain) -> String {
        "\(domain.rawValue):\(nonce)"
    }

    private func loadLocked() -> Ledger {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
            return Ledger()
        }
        return ledger
    }

    private func persistLocked(_ ledger: Ledger) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

public struct CapabilityTokenIssuerTrust: Sendable {
    public var publicKey: Curve25519.Signing.PublicKey
    public var keyId: String
    public var revoked: Bool

    public init(publicKey: Curve25519.Signing.PublicKey, keyId: String, revoked: Bool = false) {
        self.publicKey = publicKey
        self.keyId = keyId
        self.revoked = revoked
    }
}

/// Offline leaf verifier: signature + TTL + nonce-unseen + action ∈ allowed (+ attestation binding).
public struct CapabilityTokenLeafVerifier: Sendable {
    public struct Request: Sendable, Equatable {
        public var token: CapabilityToken?
        public var expectedDomain: CapabilityToken.Domain
        public var actionKind: String
        public var requiredAttestationHashBlake3: String?
        public var boundEscrowDeviceId: String?

        public init(
            token: CapabilityToken?,
            expectedDomain: CapabilityToken.Domain,
            actionKind: String,
            requiredAttestationHashBlake3: String? = nil,
            boundEscrowDeviceId: String? = nil
        ) {
            self.token = token
            self.expectedDomain = expectedDomain
            self.actionKind = actionKind
            self.requiredAttestationHashBlake3 = requiredAttestationHashBlake3
            self.boundEscrowDeviceId = boundEscrowDeviceId
        }
    }

    private let signer = CapabilityTokenSigner()
    private let nonceStore: CapabilityTokenNonceStore
    private let issuerTrustProvider: @Sendable () -> CapabilityTokenIssuerTrust?

    public init(
        nonceStore: CapabilityTokenNonceStore,
        issuerTrust: @escaping @Sendable () -> CapabilityTokenIssuerTrust?
    ) {
        self.nonceStore = nonceStore
        self.issuerTrustProvider = issuerTrust
    }

    public func verify(request: Request, now: Date = Date()) -> Result<Void, CapabilityTokenVerificationFailure> {
        guard let token = request.token else {
            return .failure(.missingToken)
        }
        guard token.domain == request.expectedDomain else {
            return .failure(.domainMismatch)
        }
        guard !token.isExpired(at: now) else {
            return .failure(.expired)
        }
        guard token.signatureEd25519Base64 != nil else {
            return .failure(.missingSignature)
        }
        guard let trust = issuerTrustProvider() else {
            return .failure(.issuerKeyUnavailable)
        }
        guard !trust.revoked else {
            return .failure(.issuerRevoked)
        }
        guard (try? signer.verify(token: token, publicKey: trust.publicKey)) == true else {
            return .failure(.signatureInvalid)
        }
        if let required = request.requiredAttestationHashBlake3 {
            guard token.attestationHashBlake3 == required else {
                return .failure(.attestationMismatch)
            }
        }
        if let bound = request.boundEscrowDeviceId ?? token.boundEscrowDeviceId {
            if let tokenBound = token.boundEscrowDeviceId, tokenBound != bound {
                return .failure(.escrowDeviceMismatch)
            }
            if token.boundEscrowDeviceId == nil, request.boundEscrowDeviceId != nil {
                return .failure(.escrowDeviceMismatch)
            }
        }
        let normalizedKind = request.actionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.allows(actionKind: normalizedKind) else {
            return .failure(.actionNotAllowed)
        }
        guard token.actionBudget > 0 else {
            return .failure(.actionBudgetExhausted)
        }
        if nonceStore.hasConsumed(nonce: token.nonce, domain: token.domain) {
            return .failure(.nonceReplay)
        }
        do {
            try nonceStore.consume(nonce: token.nonce, domain: token.domain)
        } catch let error as CapabilityTokenVerificationFailure {
            return .failure(error)
        } catch {
            return .failure(.nonceReplay)
        }
        return .success(())
    }
}
