import OpenBurnBarCore
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

struct BurnBarLinuxAppCheckAccountContext: Equatable, Sendable {
    let uid: String
    let sessionGeneration: UInt64
    let idToken: String
}

typealias BurnBarLinuxAppCheckAccountContextProvider = @Sendable () async throws -> BurnBarLinuxAppCheckAccountContext

struct BurnBarLinuxAppCheckAccountIdentity: Equatable, Sendable {
    let uid: String
    let sessionGeneration: UInt64
}

typealias BurnBarLinuxAppCheckAccountIdentityProvider = @Sendable () async -> BurnBarLinuxAppCheckAccountIdentity?

indirect enum BurnBarLinuxAppCheckJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BurnBarLinuxAppCheckJSONValue])
    case array([BurnBarLinuxAppCheckJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct BurnBarLinuxAppCheckAttestationBinding: Codable, Equatable, Sendable {
    let appId: String
    let deviceId: String
    let appVersion: String
    let architecture: String
    let releaseDigestSha256: String
    let policyId: String
    let attestationKind: String
}

struct BurnBarLinuxAppCheckChallenge: Codable, Equatable, Sendable {
    let challengeId: String
    let challenge: String
    let expiresAtMillis: Int64
    let appId: String
    let policyId: String
    let protocolVersion: Int
}

struct BurnBarLinuxAppCheckAttestation: Codable, Equatable, Sendable {
    let challengeId: String
    let challenge: String
    let kind: String
    let evidence: BurnBarLinuxAppCheckJSONValue
}

protocol BurnBarLinuxAppCheckAttestationProviding: Sendable {
    func makeBinding(appID: String) async throws -> BurnBarLinuxAppCheckAttestationBinding
    func makeAttestation(
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAppCheckAttestation
}

struct BurnBarLinuxAppCheckMintResponse: Equatable, Sendable {
    let appCheckToken: String
    let issuedAtMillis: Int64
    let expireTimeMillis: Int64
    let appID: String
    let trustClass: String

    init(
        appCheckToken: String,
        issuedAtMillis: Int64? = nil,
        expireTimeMillis: Int64,
        appID: String,
        trustClass: String
    ) {
        self.appCheckToken = appCheckToken
        self.issuedAtMillis = issuedAtMillis ?? expireTimeMillis - Int64(30 * 60 * 1_000)
        self.expireTimeMillis = expireTimeMillis
        self.appID = appID
        self.trustClass = trustClass
    }
}

protocol BurnBarLinuxAppCheckCloudClient: Sendable {
    func issueChallenge(
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckChallenge

    func mintToken(
        attestation: BurnBarLinuxAppCheckAttestation,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckMintResponse
}

struct BurnBarLinuxAppCheckToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date
    let appID: String
    let trustClass: String
}

enum BurnBarLinuxAppCheckStatus: Equatable, Sendable {
    case unavailable
    case acquiring
    case ready(expiresAt: Date, appID: String, trustClass: String)
}

enum BurnBarLinuxAppCheckError: Error, Equatable, Sendable {
    case accountUnavailable
    case invalidAccountContext
    case invalidAttestation
    case invalidResponse
    case unexpectedAppID
    case unacceptableTrustClass
    case invalidTTL
    case accountChanged
    case networkUnavailable
    case attestationUnavailable
}

private struct UnavailableBurnBarLinuxAppCheckAttestationProvider: BurnBarLinuxAppCheckAttestationProviding {
    func makeBinding(appID _: String) async throws -> BurnBarLinuxAppCheckAttestationBinding {
        throw BurnBarLinuxAppCheckError.attestationUnavailable
    }

    func makeAttestation(
        challenge _: BurnBarLinuxAppCheckChallenge,
        binding _: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAppCheckAttestation {
        throw BurnBarLinuxAppCheckError.attestationUnavailable
    }
}

public actor BurnBarLinuxAppCheckService {
    static let minimumTTL: TimeInterval = 30 * 60
    static let maximumTTL: TimeInterval = 30 * 60
    static let expiryClockSkew: TimeInterval = 60
    static let defaultRefreshLeadTime: TimeInterval = 5 * 60

    private struct AccountIdentity: Equatable, Sendable {
        let uid: String
        let sessionGeneration: UInt64
    }

    private struct CachedToken: Sendable {
        let token: BurnBarLinuxAppCheckToken
        let identity: AccountIdentity
    }

    private struct Acquisition: Sendable {
        let id: UInt64
        let identity: AccountIdentity
        let startedAt: Date
        let task: Task<BurnBarLinuxAppCheckMintResponse, Error>
    }

    private let expectedAppID: String
    private let acceptedTrustClasses: Set<String>
    private let refreshLeadTime: TimeInterval
    private let accountContext: BurnBarLinuxAppCheckAccountContextProvider
    private let accountIdentity: BurnBarLinuxAppCheckAccountIdentityProvider
    private let attestationProvider: any BurnBarLinuxAppCheckAttestationProviding
    private let cloudClient: any BurnBarLinuxAppCheckCloudClient
    private let now: @Sendable () -> Date

    private var cachedToken: CachedToken?
    private var acquisition: Acquisition?
    private var nextAcquisitionID: UInt64 = 0

    init(
        expectedAppID: String,
        acceptedTrustClasses: Set<String> = ["linux_lower_trust"],
        refreshLeadTime: TimeInterval = BurnBarLinuxAppCheckService.defaultRefreshLeadTime,
        accountContext: @escaping BurnBarLinuxAppCheckAccountContextProvider,
        accountIdentity: @escaping BurnBarLinuxAppCheckAccountIdentityProvider,
        attestationProvider: any BurnBarLinuxAppCheckAttestationProviding,
        cloudClient: any BurnBarLinuxAppCheckCloudClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.expectedAppID = expectedAppID
        self.acceptedTrustClasses = acceptedTrustClasses
        self.refreshLeadTime = refreshLeadTime
        self.accountContext = accountContext
        self.accountIdentity = accountIdentity
        self.attestationProvider = attestationProvider
        self.cloudClient = cloudClient
        self.now = now
    }

    static func production(
        accountContext: @escaping BurnBarLinuxAppCheckAccountContextProvider,
        accountIdentity: @escaping BurnBarLinuxAppCheckAccountIdentityProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) -> BurnBarLinuxAppCheckService {
        BurnBarLinuxAppCheckService(
            expectedAppID: environment["OPENBURNBAR_LINUX_APP_CHECK_APP_ID"]
                ?? "1:000000000000:linux:0000000000000000placeholder",
            accountContext: accountContext,
            accountIdentity: accountIdentity,
            attestationProvider: UnavailableBurnBarLinuxAppCheckAttestationProvider(),
            cloudClient: EnvironmentBurnBarLinuxAppCheckCloudClient(
                environment: environment,
                session: session
            )
        )
    }

    func validToken() async throws -> BurnBarLinuxAppCheckToken {
        guard expectedAppID.trimmingCharacters(in: .whitespacesAndNewlines) == expectedAppID,
              expectedAppID.isEmpty == false,
              expectedAppID.utf8.count <= 512,
              acceptedTrustClasses.isEmpty == false,
              refreshLeadTime >= 0,
              refreshLeadTime < Self.minimumTTL else {
            invalidateAll()
            throw BurnBarLinuxAppCheckError.invalidResponse
        }

        let context: BurnBarLinuxAppCheckAccountContext
        do {
            context = try await accountContext()
        } catch {
            invalidateAll()
            throw BurnBarLinuxAppCheckError.accountUnavailable
        }

        let identity: AccountIdentity
        do {
            identity = try validatedIdentity(context)
        } catch {
            invalidateAll()
            throw error
        }
        if let cachedToken,
           cachedToken.identity == identity,
           cachedToken.token.expiresAt.timeIntervalSince(now()) > refreshLeadTime {
            return cachedToken.token
        }
        if cachedToken?.identity != identity { cachedToken = nil }

        let currentAcquisition: Acquisition
        if let acquisition, acquisition.identity == identity {
            currentAcquisition = acquisition
        } else {
            acquisition?.task.cancel()
            nextAcquisitionID &+= 1
            let acquisitionID = nextAcquisitionID
            let startedAt = now()
            let expectedAppID = self.expectedAppID
            let attestationProvider = self.attestationProvider
            let cloudClient = self.cloudClient
            let idToken = context.idToken
            let task = Task<BurnBarLinuxAppCheckMintResponse, Error> {
                let binding = try await attestationProvider.makeBinding(appID: expectedAppID)
                guard Self.isValidBinding(binding, expectedAppID: expectedAppID) else {
                    throw BurnBarLinuxAppCheckError.invalidAttestation
                }
                let challenge = try await cloudClient.issueChallenge(binding: binding, idToken: idToken)
                guard Self.isValidChallenge(
                    challenge,
                    binding: binding,
                    expectedAppID: expectedAppID,
                    now: startedAt
                ) else {
                    throw BurnBarLinuxAppCheckError.invalidResponse
                }
                let attestation = try await attestationProvider.makeAttestation(
                    challenge: challenge,
                    binding: binding
                )
                guard attestation.challengeId == challenge.challengeId,
                      attestation.challenge == challenge.challenge,
                      attestation.kind == binding.attestationKind else {
                    throw BurnBarLinuxAppCheckError.invalidAttestation
                }
                return try await cloudClient.mintToken(attestation: attestation, idToken: idToken)
            }
            currentAcquisition = Acquisition(
                id: acquisitionID,
                identity: identity,
                startedAt: startedAt,
                task: task
            )
            acquisition = currentAcquisition
        }

        let response: BurnBarLinuxAppCheckMintResponse
        do {
            response = try await currentAcquisition.task.value
        } catch {
            clearAcquisition(id: currentAcquisition.id)
            throw error
        }

        let latestContext: BurnBarLinuxAppCheckAccountContext
        do {
            latestContext = try await accountContext()
        } catch {
            clearAcquisition(id: currentAcquisition.id)
            cachedToken = nil
            throw BurnBarLinuxAppCheckError.accountChanged
        }
        let latestIdentity: AccountIdentity
        do {
            latestIdentity = try validatedIdentity(latestContext)
        } catch {
            clearAcquisition(id: currentAcquisition.id)
            cachedToken = nil
            throw BurnBarLinuxAppCheckError.accountChanged
        }
        guard latestIdentity == identity else {
            clearAcquisition(id: currentAcquisition.id)
            cachedToken = nil
            throw BurnBarLinuxAppCheckError.accountChanged
        }

        let token: BurnBarLinuxAppCheckToken
        do {
            token = try validatedToken(response, startedAt: currentAcquisition.startedAt, receivedAt: now())
        } catch {
            clearAcquisition(id: currentAcquisition.id)
            throw error
        }
        guard acquisition?.id == currentAcquisition.id else {
            if let cachedToken, cachedToken.identity == identity { return cachedToken.token }
            throw BurnBarLinuxAppCheckError.accountChanged
        }
        cachedToken = CachedToken(token: token, identity: identity)
        acquisition = nil
        return token
    }

    func status() async -> BurnBarLinuxAppCheckStatus {
        guard acquisition != nil || cachedToken != nil else { return .unavailable }
        guard let snapshot = await accountIdentity(),
              let identity = validatedIdentity(snapshot) else {
            invalidateAll()
            return .unavailable
        }
        if let acquisition, acquisition.identity != identity {
            invalidateAll()
            return .unavailable
        }
        if let cachedToken, cachedToken.identity != identity {
            invalidateAll()
            return .unavailable
        }
        if acquisition != nil { return .acquiring }
        guard let cachedToken else { return .unavailable }
        guard cachedToken.token.expiresAt > now() else {
            self.cachedToken = nil
            return .unavailable
        }
        return .ready(
            expiresAt: cachedToken.token.expiresAt,
            appID: cachedToken.token.appID,
            trustClass: cachedToken.token.trustClass
        )
    }

    func redactedStatusResponse() async -> BurnBarLinuxAppCheckStatusResponse {
        switch await status() {
        case .unavailable:
            return BurnBarLinuxAppCheckStatusResponse(state: .unavailable)
        case .acquiring:
            return BurnBarLinuxAppCheckStatusResponse(state: .acquiring)
        case .ready(let expiresAt, _, let trustClass):
            return BurnBarLinuxAppCheckStatusResponse(
                state: .ready,
                trustClass: trustClass,
                expiresAt: ISO8601DateFormatter().string(from: expiresAt)
            )
        }
    }

    func invalidate() { invalidateAll() }

    private func validatedIdentity(_ context: BurnBarLinuxAppCheckAccountContext) throws -> AccountIdentity {
        let uid = context.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let idToken = context.idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uid.isEmpty == false,
              uid.utf8.count <= 256,
              idToken.isEmpty == false,
              idToken.utf8.count <= 16_384 else {
            throw BurnBarLinuxAppCheckError.invalidAccountContext
        }
        return AccountIdentity(uid: uid, sessionGeneration: context.sessionGeneration)
    }

    private func validatedIdentity(_ snapshot: BurnBarLinuxAppCheckAccountIdentity) -> AccountIdentity? {
        let uid = snapshot.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uid.isEmpty == false, uid.utf8.count <= 256 else { return nil }
        return AccountIdentity(uid: uid, sessionGeneration: snapshot.sessionGeneration)
    }

    private func validatedToken(
        _ response: BurnBarLinuxAppCheckMintResponse,
        startedAt: Date,
        receivedAt: Date
    ) throws -> BurnBarLinuxAppCheckToken {
        guard response.appID == expectedAppID else { throw BurnBarLinuxAppCheckError.unexpectedAppID }
        guard acceptedTrustClasses.contains(response.trustClass) else {
            throw BurnBarLinuxAppCheckError.unacceptableTrustClass
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(response.issuedAtMillis) / 1_000)
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(response.expireTimeMillis) / 1_000)
        guard expiresAt.timeIntervalSince(receivedAt) > refreshLeadTime,
              issuedAt >= startedAt.addingTimeInterval(-Self.expiryClockSkew),
              issuedAt <= receivedAt.addingTimeInterval(Self.expiryClockSkew),
              expiresAt.timeIntervalSince(issuedAt) >= Self.minimumTTL - Self.expiryClockSkew,
              expiresAt.timeIntervalSince(issuedAt) <= Self.maximumTTL + Self.expiryClockSkew else {
            throw BurnBarLinuxAppCheckError.invalidTTL
        }
        let value = response.appCheckToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value.utf8.count <= 16_384 else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
        return .init(value: value, expiresAt: expiresAt, appID: response.appID, trustClass: response.trustClass)
    }

    private func clearAcquisition(id: UInt64) {
        if acquisition?.id == id { acquisition = nil }
    }

    private func invalidateAll() {
        cachedToken = nil
        acquisition?.task.cancel()
        acquisition = nil
    }

    private static func isValidBinding(
        _ binding: BurnBarLinuxAppCheckAttestationBinding,
        expectedAppID: String
    ) -> Bool {
        binding.appId == expectedAppID
            && isSafeLabel(binding.deviceId, maximum: 160)
            && isSafeLabel(binding.appVersion, maximum: 80)
            && isSafeLabel(binding.architecture, maximum: 24)
            && binding.releaseDigestSha256.utf8.count == 64
            && binding.releaseDigestSha256.allSatisfy { "0123456789abcdef".contains($0) }
            && isSafeLabel(binding.policyId, maximum: 160)
            && isSafeLabel(binding.attestationKind, maximum: 80)
    }

    private static func isValidChallenge(
        _ challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding,
        expectedAppID: String,
        now: Date
    ) -> Bool {
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(challenge.expiresAtMillis) / 1_000)
        return challenge.protocolVersion == 1
            && challenge.appId == expectedAppID
            && challenge.policyId == binding.policyId
            && (16...256).contains(challenge.challengeId.utf8.count)
            && (16...256).contains(challenge.challenge.utf8.count)
            && expiresAt > now
            && expiresAt.timeIntervalSince(now) <= 5 * 60
    }

    private static func isSafeLabel(_ value: String, maximum: Int) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= maximum
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-".contains($0) }
    }
}
