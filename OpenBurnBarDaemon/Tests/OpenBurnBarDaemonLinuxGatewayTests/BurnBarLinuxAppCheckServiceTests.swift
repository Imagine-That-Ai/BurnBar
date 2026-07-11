@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxAppCheckServiceTests: XCTestCase {
    private let appID = "1:123456789:web:linuxappcheck"
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    func testConcurrentRequestsSingleFlightChallengeMintAndMemoryCache() async throws {
        let accounts = AppCheckAccountFixture(
            .init(uid: "user-1", sessionGeneration: 7, idToken: "firebase-id-token")
        )
        let attestation = AppCheckAttestationFixture()
        let cloud = AppCheckCloudFixture(
            responses: [validResponse()],
            challengeExpiry: start.addingTimeInterval(120),
            delayNanoseconds: 25_000_000
        )
        let service = makeService(accounts: accounts, attestation: attestation, cloud: cloud)

        async let first = service.validToken()
        async let second = service.validToken()
        let (firstToken, secondToken) = try await (first, second)

        XCTAssertEqual(firstToken, secondToken)
        XCTAssertEqual(firstToken.value, "app-check-secret")
        let providerCounts = await attestation.callCounts()
        let cloudCounts = await cloud.callCounts()
        XCTAssertEqual(providerCounts.bindings, 1)
        XCTAssertEqual(providerCounts.attestations, 1)
        XCTAssertEqual(cloudCounts.challenges, 1)
        XCTAssertEqual(cloudCounts.mints, 1)
        let cached = try await service.validToken()
        XCTAssertEqual(cached, firstToken)
        let cachedCounts = await cloud.callCounts()
        XCTAssertEqual(cachedCounts.mints, 1)
        let status = await service.status()
        XCTAssertEqual(
            status,
            .ready(
                expiresAt: start.addingTimeInterval(30 * 60),
                appID: appID,
                trustClass: "linux_lower_trust"
            )
        )
        let redacted = await service.redactedStatusResponse()
        XCTAssertEqual(redacted.state, .ready)
        XCTAssertEqual(redacted.trustClass, "linux_lower_trust")
        XCTAssertEqual(redacted.expiresAt, "2030-03-17T18:16:40Z")
        let encodedStatus = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        XCTAssertFalse(encodedStatus.contains("app-check-secret"))
        XCTAssertFalse(encodedStatus.contains(appID))
    }

    func testRefreshLeadForcesNewChallengeAndMint() async throws {
        let clock = AppCheckClock(start)
        let accounts = AppCheckAccountFixture(
            .init(uid: "user-1", sessionGeneration: 1, idToken: "id-token")
        )
        let cloud = AppCheckCloudFixture(
            responses: [
                validResponse(expiresAt: start.addingTimeInterval(30 * 60)),
                validResponse(expiresAt: start.addingTimeInterval(55 * 60))
            ],
            challengeExpiries: [
                start.addingTimeInterval(2 * 60),
                start.addingTimeInterval(27 * 60)
            ]
        )
        let service = makeService(
            accounts: accounts,
            attestation: AppCheckAttestationFixture(),
            cloud: cloud,
            clock: clock
        )

        _ = try await service.validToken()
        clock.advance(by: 25 * 60 + 1)
        _ = try await service.validToken()

        let counts = await cloud.callCounts()
        XCTAssertEqual(counts.challenges, 2)
        XCTAssertEqual(counts.mints, 2)
    }

    func testAccountGenerationChangeDuringMintDiscardsResult() async throws {
        let accounts = AppCheckAccountFixture(
            .init(uid: "user-1", sessionGeneration: 4, idToken: "id-token-1")
        )
        let cloud = SuspendedAppCheckCloudFixture(
            response: validResponse(),
            challengeExpiry: start.addingTimeInterval(120)
        )
        let service = makeService(
            accounts: accounts,
            attestation: AppCheckAttestationFixture(),
            cloud: cloud
        )

        let request = Task { try await service.validToken() }
        await cloud.waitUntilMintStarted()
        await accounts.set(.init(uid: "user-2", sessionGeneration: 5, idToken: "id-token-2"))
        await cloud.releaseMint()

        do {
            _ = try await request.value
            XCTFail("A token minted for the previous account must not escape")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .accountChanged)
        }
        let status = await service.status()
        XCTAssertEqual(status, .unavailable)
    }

    func testStatusInvalidatesCachedTokenWhenAccountBecomesUnavailable() async throws {
        let accounts = AppCheckAccountFixture(
            .init(uid: "user-1", sessionGeneration: 4, idToken: "id-token")
        )
        let service = makeService(
            accounts: accounts,
            attestation: AppCheckAttestationFixture(),
            cloud: AppCheckCloudFixture(
                responses: [validResponse()],
                challengeExpiry: start.addingTimeInterval(120)
            )
        )

        _ = try await service.validToken()
        await accounts.set(nil)

        let status = await service.status()
        XCTAssertEqual(status, .unavailable)
        do {
            _ = try await service.validToken()
            XCTFail("A cached token must not survive account invalidation")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .accountUnavailable)
        }
    }

    func testSlowAttestationAcceptsTTLAnchoredToServerIssueTime() async throws {
        let clock = AppCheckClock(start)
        let accounts = AppCheckAccountFixture(
            .init(uid: "user-1", sessionGeneration: 4, idToken: "id-token")
        )
        let issuedAt = start.addingTimeInterval(90)
        let cloud = SuspendedAppCheckCloudFixture(
            response: validResponse(expiresAt: issuedAt.addingTimeInterval(30 * 60)),
            challengeExpiry: start.addingTimeInterval(120)
        )
        let service = makeService(
            accounts: accounts,
            attestation: AppCheckAttestationFixture(),
            cloud: cloud,
            clock: clock
        )

        let request = Task { try await service.validToken() }
        await cloud.waitUntilMintStarted()
        clock.advance(by: 90)
        await cloud.releaseMint()

        let token = try await request.value
        XCTAssertEqual(token.expiresAt, issuedAt.addingTimeInterval(30 * 60))
    }

    func testWrongAppTrustTTLAndMalformedTokenFailClosed() async throws {
        let cases: [(BurnBarLinuxAppCheckMintResponse, BurnBarLinuxAppCheckError)] = [
            (
                .init(
                    appCheckToken: "token",
                    expireTimeMillis: millis(start.addingTimeInterval(30 * 60)),
                    appID: "1:evil:web:app",
                    trustClass: "linux_lower_trust"
                ),
                .unexpectedAppID
            ),
            (
                .init(
                    appCheckToken: "token",
                    expireTimeMillis: millis(start.addingTimeInterval(30 * 60)),
                    appID: appID,
                    trustClass: "unverified_fixture"
                ),
                .unacceptableTrustClass
            ),
            (
                .init(
                    appCheckToken: "token",
                    expireTimeMillis: millis(start.addingTimeInterval(10 * 60)),
                    appID: appID,
                    trustClass: "linux_lower_trust"
                ),
                .invalidTTL
            ),
            (
                .init(
                    appCheckToken: "token",
                    expireTimeMillis: millis(start.addingTimeInterval(32 * 60)),
                    appID: appID,
                    trustClass: "linux_lower_trust"
                ),
                .invalidTTL
            ),
            (
                .init(
                    appCheckToken: " ",
                    expireTimeMillis: millis(start.addingTimeInterval(30 * 60)),
                    appID: appID,
                    trustClass: "linux_lower_trust"
                ),
                .invalidResponse
            )
        ]

        for (response, expectedError) in cases {
            let accounts = AppCheckAccountFixture(
                .init(uid: "user", sessionGeneration: 1, idToken: "id-token")
            )
            let service = makeService(
                accounts: accounts,
                attestation: AppCheckAttestationFixture(),
                cloud: AppCheckCloudFixture(
                    responses: [response],
                    challengeExpiry: start.addingTimeInterval(120)
                )
            )
            do {
                _ = try await service.validToken()
                XCTFail("Invalid mint response should fail closed")
            } catch let error as BurnBarLinuxAppCheckError {
                XCTAssertEqual(error, expectedError)
            }
            let status = await service.status()
            XCTAssertEqual(status, .unavailable)
        }
    }

    func testMismatchedEvidenceNeverReachesMint() async throws {
        let accounts = AppCheckAccountFixture(
            .init(uid: "user", sessionGeneration: 1, idToken: "id-token")
        )
        let provider = AppCheckAttestationFixture(mismatchChallenge: true)
        let cloud = AppCheckCloudFixture(
            responses: [validResponse()],
            challengeExpiry: start.addingTimeInterval(120)
        )
        let service = makeService(accounts: accounts, attestation: provider, cloud: cloud)

        do {
            _ = try await service.validToken()
            XCTFail("Evidence must remain bound to the issued challenge")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidAttestation)
        }
        let counts = await cloud.callCounts()
        XCTAssertEqual(counts.challenges, 1)
        XCTAssertEqual(counts.mints, 0)
    }

    func testMalformedAccountContextFailsBeforeChallenge() async throws {
        let accounts = AppCheckAccountFixture(
            .init(uid: " ", sessionGeneration: 1, idToken: "id-token")
        )
        let cloud = AppCheckCloudFixture(
            responses: [validResponse()],
            challengeExpiry: start.addingTimeInterval(120)
        )
        let service = makeService(
            accounts: accounts,
            attestation: AppCheckAttestationFixture(),
            cloud: cloud
        )
        do {
            _ = try await service.validToken()
            XCTFail("Malformed account context should fail closed")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidAccountContext)
        }
        let counts = await cloud.callCounts()
        XCTAssertEqual(counts.challenges, 0)
        XCTAssertEqual(counts.mints, 0)
    }

    private func validResponse(expiresAt: Date? = nil) -> BurnBarLinuxAppCheckMintResponse {
        .init(
            appCheckToken: "app-check-secret",
            expireTimeMillis: millis(expiresAt ?? start.addingTimeInterval(30 * 60)),
            appID: appID,
            trustClass: "linux_lower_trust"
        )
    }

    private func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func makeService(
        accounts: AppCheckAccountFixture,
        attestation: any BurnBarLinuxAppCheckAttestationProviding,
        cloud: any BurnBarLinuxAppCheckCloudClient,
        clock: AppCheckClock? = nil
    ) -> BurnBarLinuxAppCheckService {
        let resolvedClock = clock ?? AppCheckClock(start)
        return .init(
            expectedAppID: appID,
            accountContext: { try await accounts.current() },
            accountIdentity: { await accounts.identity() },
            attestationProvider: attestation,
            cloudClient: cloud,
            now: { resolvedClock.now() }
        )
    }
}

private final class AppCheckClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor AppCheckAccountFixture {
    private var context: BurnBarLinuxAppCheckAccountContext?
    init(_ context: BurnBarLinuxAppCheckAccountContext?) { self.context = context }
    func current() throws -> BurnBarLinuxAppCheckAccountContext {
        guard let context else { throw BurnBarLinuxAppCheckError.accountUnavailable }
        return context
    }
    func identity() -> BurnBarLinuxAppCheckAccountIdentity? {
        context.map { .init(uid: $0.uid, sessionGeneration: $0.sessionGeneration) }
    }
    func set(_ context: BurnBarLinuxAppCheckAccountContext?) { self.context = context }
}

private actor AppCheckAttestationFixture: BurnBarLinuxAppCheckAttestationProviding {
    private let mismatchChallenge: Bool
    private var bindingCalls = 0
    private var attestationCalls = 0

    init(mismatchChallenge: Bool = false) { self.mismatchChallenge = mismatchChallenge }

    func makeBinding(appID: String) async throws -> BurnBarLinuxAppCheckAttestationBinding {
        bindingCalls += 1
        return .init(
            appId: appID,
            deviceId: "device-1",
            appVersion: "1.0.0",
            architecture: "x86_64",
            releaseDigestSha256: String(repeating: "a", count: 64),
            policyId: "openburnbar-linux-tpm2-ima-v1",
            attestationKind: "tpm2_ima_signed_verdict_v1"
        )
    }

    func makeAttestation(
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken _: String
    ) async throws -> BurnBarLinuxAppCheckAttestation {
        attestationCalls += 1
        return .init(
            challengeId: mismatchChallenge ? "different-challenge-identifier" : challenge.challengeId,
            challenge: challenge.challenge,
            kind: binding.attestationKind,
            evidence: .object(["quote": .string("fixture-quote")])
        )
    }

    func callCounts() -> (bindings: Int, attestations: Int) {
        (bindingCalls, attestationCalls)
    }
}

private actor AppCheckCloudFixture: BurnBarLinuxAppCheckCloudClient {
    private var responses: [BurnBarLinuxAppCheckMintResponse]
    private var challengeExpiries: [Date]
    private let delayNanoseconds: UInt64
    private var challengeCalls = 0
    private var mintCalls = 0

    init(
        responses: [BurnBarLinuxAppCheckMintResponse],
        challengeExpiry: Date,
        delayNanoseconds: UInt64 = 0
    ) {
        self.responses = responses
        challengeExpiries = [challengeExpiry]
        self.delayNanoseconds = delayNanoseconds
    }

    init(
        responses: [BurnBarLinuxAppCheckMintResponse],
        challengeExpiries: [Date],
        delayNanoseconds: UInt64 = 0
    ) {
        self.responses = responses
        self.challengeExpiries = challengeExpiries
        self.delayNanoseconds = delayNanoseconds
    }

    func issueChallenge(
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken _: String
    ) async throws -> BurnBarLinuxAppCheckChallenge {
        challengeCalls += 1
        guard let challengeExpiry = challengeExpiries.first else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
        if challengeExpiries.count > 1 { challengeExpiries.removeFirst() }
        return .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            expiresAtMillis: Int64(challengeExpiry.timeIntervalSince1970 * 1_000),
            appId: binding.appId,
            policyId: binding.policyId,
            protocolVersion: 1
        )
    }

    func mintToken(
        attestation _: BurnBarLinuxAppCheckAttestation,
        idToken _: String
    ) async throws -> BurnBarLinuxAppCheckMintResponse {
        mintCalls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        guard responses.isEmpty == false else { throw BurnBarLinuxAppCheckError.invalidResponse }
        return responses.removeFirst()
    }

    func callCounts() -> (challenges: Int, mints: Int) { (challengeCalls, mintCalls) }
}

private actor SuspendedAppCheckCloudFixture: BurnBarLinuxAppCheckCloudClient {
    private let response: BurnBarLinuxAppCheckMintResponse
    private let challengeExpiry: Date
    private var mintStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(response: BurnBarLinuxAppCheckMintResponse, challengeExpiry: Date) {
        self.response = response
        self.challengeExpiry = challengeExpiry
    }

    func issueChallenge(
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken _: String
    ) async throws -> BurnBarLinuxAppCheckChallenge {
        .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            expiresAtMillis: Int64(challengeExpiry.timeIntervalSince1970 * 1_000),
            appId: binding.appId,
            policyId: binding.policyId,
            protocolVersion: 1
        )
    }

    func mintToken(
        attestation _: BurnBarLinuxAppCheckAttestation,
        idToken _: String
    ) async throws -> BurnBarLinuxAppCheckMintResponse {
        mintStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return response
    }

    func waitUntilMintStarted() async {
        if mintStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseMint() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
