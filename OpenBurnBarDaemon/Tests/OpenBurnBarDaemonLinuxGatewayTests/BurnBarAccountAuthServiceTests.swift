import XCTest
@testable import OpenBurnBarDaemon
import OpenBurnBarCore
import OpenBurnBarLinuxSecurity

final class BurnBarAccountAuthServiceTests: XCTestCase {
    private let flowID = "123E4567-E89B-12D3-A456-426614174000"
    private let fixedDate = Date(timeIntervalSince1970: 1_783_296_000)

    func testDeviceAuthorizationPersistsRefreshBeforePublishingRedactedProfile() async throws {
        let events = EventRecorder()
        let backend = RecordingSecretBackend(events: events)
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let identityClient = IdentityClientStub(events: events, baseDate: fixedDate)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: identityClient
        )

        let started = try await service.startDeviceAuthorization()
        XCTAssertEqual(started.account.state, .authorizationPending)
        XCTAssertEqual(started.account.session?.flowID, flowID)
        XCTAssertEqual(started.account.session?.verificationURL, "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth")

        let recordedStartRequest = await deviceClient.recordedStartRequest()
        let startRequest = try XCTUnwrap(recordedStartRequest)
        XCTAssertEqual(startRequest.purpose, "desktop_auth")
        XCTAssertEqual(startRequest.clientType, "desktop_linux")
        XCTAssertEqual(startRequest.credentialDelivery.flowBinding, flowID)
        XCTAssertEqual(startRequest.credentialDelivery.algorithm, LinuxDesktopAuthDeliveryKey.algorithm)
        XCTAssertEqual(startRequest.deviceSecretHash.count, 64)
        XCTAssertTrue(startRequest.deviceSecretHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let approved = try await service.pollDeviceAuthorization(flowID: flowID.lowercased())
        XCTAssertEqual(approved.account.state, .signedIn)
        XCTAssertEqual(approved.account.uid, "firebase-user-1")
        XCTAssertEqual(approved.account.email, "person@example.com")
        XCTAssertEqual(approved.account.syncState, "local_only")
        XCTAssertNil(approved.account.session)
        XCTAssertEqual(events.snapshot(), ["store:refresh-token-1", "profile"])
        XCTAssertEqual(backend.secret(), "refresh-token-1")

        let encoded = String(decoding: try JSONEncoder().encode(approved), as: UTF8.self)
        XCTAssertFalse(encoded.contains("custom-token"))
        XCTAssertFalse(encoded.contains("id-token"))
        XCTAssertFalse(encoded.contains("refresh-token"))
        XCTAssertFalse(encoded.contains("device-secret"))
    }

    func testApprovedExchangeFailureReturnsTerminalStructuredState() async throws {
        let backend = RecordingSecretBackend()
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: IdentityClientStub(
                baseDate: fixedDate,
                signInError: .networkUnavailable
            )
        )
        _ = try await service.startDeviceAuthorization()

        let failed = try await service.pollDeviceAuthorization(flowID: flowID)
        XCTAssertEqual(failed.account.state, .signedOut)
        XCTAssertEqual(failed.account.problem?.code, .networkUnavailable)
        XCTAssertNil(failed.account.session)
        XCTAssertNil(backend.secret())

        do {
            _ = try await service.pollDeviceAuthorization(flowID: flowID)
            XCTFail("Expected the consumed approval flow to remain terminal")
        } catch let error as BurnBarAccountAuthError {
            XCTAssertEqual(error, .invalidFlow)
        }
    }

    func testCancelDiscardsLocalAuthorityOfflineAndIsIdempotent() async throws {
        let backend = RecordingSecretBackend()
        let deviceClient = DeviceAuthClientStub(cancelError: .networkUnavailable)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: IdentityClientStub(baseDate: fixedDate)
        )
        _ = try await service.startDeviceAuthorization()

        let cancelled = try await service.cancelDeviceAuthorization(flowID: flowID)
        XCTAssertEqual(cancelled.account.state, .signedOut)
        let repeated = try await service.cancelDeviceAuthorization(flowID: flowID)
        XCTAssertEqual(repeated.account.state, .signedOut)
        for _ in 0..<100 {
            if await deviceClient.cancelCount() > 0 { break }
            await Task.yield()
        }
        let cancellationCount = await deviceClient.cancelCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testRefreshIsSingleFlightAndPersistsRotationBeforeUse() async throws {
        let clock = TestClock(fixedDate)
        let events = EventRecorder()
        let backend = RecordingSecretBackend(events: events)
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let identityClient = IdentityClientStub(
            events: events,
            baseDate: fixedDate,
            refreshDelayNanoseconds: 50_000_000
        )
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: identityClient,
            now: { clock.now() }
        )
        _ = try await service.startDeviceAuthorization()
        _ = try await service.pollDeviceAuthorization(flowID: flowID)
        clock.advance(by: 3_700)

        async let first = service.validIDToken()
        async let second = service.validIDToken()
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["id-token-rotated", "id-token-rotated"])
        let refreshCount = await identityClient.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(backend.secret(), "refresh-token-rotated")
        XCTAssertEqual(Array(events.snapshot().suffix(2)), ["refresh", "store:refresh-token-rotated"])
    }

    func testSignOutClearsLocalAuthorityWithoutWaitingForOfflineCancellation() async throws {
        let backend = RecordingSecretBackend(initialSecret: "persisted-refresh")
        let deviceClient = DeviceAuthClientStub(cancelError: .networkUnavailable)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: IdentityClientStub(baseDate: fixedDate)
        )
        _ = try await service.startDeviceAuthorization()

        let firstSignOut = try await service.signOut()
        XCTAssertEqual(firstSignOut.account.state, .signedOut)
        let secondSignOut = try await service.signOut()
        XCTAssertEqual(secondSignOut.account.state, .signedOut)
        XCTAssertNil(backend.secret())
        let cancellationCount = await deviceClient.cancelCount()
        XCTAssertEqual(cancellationCount, 0)
    }

    func testSignOutDeletionFailureRetainsSessionAndRestartAuthority() async throws {
        let backend = RecordingSecretBackend()
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let identityClient = IdentityClientStub(baseDate: fixedDate)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: identityClient
        )
        _ = try await service.startDeviceAuthorization()
        _ = try await service.pollDeviceAuthorization(flowID: flowID)
        XCTAssertEqual(backend.secret(), "refresh-token-1")

        backend.setDeleteError(.commandFailed(
            backend: backend.backendName,
            operation: "delete",
            detail: "locked"
        ))
        do {
            _ = try await service.signOut()
            XCTFail("Expected sign-out to fail when the keyring cannot delete the credential")
        } catch let error as BurnBarAccountAuthError {
            XCTAssertEqual(error, .secretStoreUnavailable)
        }
        let retained = await service.status()
        XCTAssertEqual(retained.account.state, .signedIn)
        XCTAssertEqual(retained.account.uid, "firebase-user-1")
        XCTAssertEqual(backend.secret(), "refresh-token-1")

        let fixedDate = self.fixedDate
        let restarted = BurnBarAccountAuthService(
            deviceAuthClient: DeviceAuthClientStub(),
            identityClient: IdentityClientStub(baseDate: fixedDate),
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend])),
            configuredFirebaseAPIKey: "fixture-public-api-key",
            now: { fixedDate }
        )
        let restored = await restarted.status()
        XCTAssertEqual(restored.account.state, .signedIn)
        XCTAssertEqual(restored.account.uid, "firebase-user-1")

        backend.setDeleteError(nil)
        let signedOut = try await restarted.signOut()
        XCTAssertEqual(signedOut.account.state, .signedOut)
        XCTAssertNil(backend.secret())

        let afterSuccessfulSignOut = BurnBarAccountAuthService(
            deviceAuthClient: DeviceAuthClientStub(),
            identityClient: IdentityClientStub(baseDate: fixedDate),
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend])),
            configuredFirebaseAPIKey: "fixture-public-api-key",
            now: { fixedDate }
        )
        let finalRestartStatus = await afterSuccessfulSignOut.status()
        XCTAssertEqual(finalRestartStatus.account.state, .signedOut)
    }

    func testSignOutFencesNonCooperativeRefreshBeforeItCanRewriteSecret() async throws {
        let clock = TestClock(fixedDate)
        let gate = RefreshGate()
        let backend = RecordingSecretBackend()
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let identityClient = IdentityClientStub(baseDate: fixedDate, refreshGate: gate)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: identityClient,
            now: { clock.now() }
        )
        _ = try await service.startDeviceAuthorization()
        _ = try await service.pollDeviceAuthorization(flowID: flowID)
        clock.advance(by: 3_700)

        let refresh = Task { try await service.validIDToken() }
        await gate.waitUntilStarted()
        let signedOut = try await service.signOut()
        XCTAssertEqual(signedOut.account.state, .signedOut)
        XCTAssertNil(backend.secret())

        await gate.release()
        do {
            _ = try await refresh.value
            XCTFail("Expected the refresh from the signed-out generation to be rejected")
        } catch let error as BurnBarAccountAuthError {
            XCTAssertEqual(error, .reauthenticationRequired)
        }
        XCTAssertNil(backend.secret())
        let finalStatus = await service.status()
        XCTAssertEqual(finalStatus.account.state, .signedOut)
    }

    func testSignOutFencesDelayedCustomTokenExchangeBeforePersistence() async throws {
        let gate = RefreshGate()
        let backend = RecordingSecretBackend()
        let deviceClient = DeviceAuthClientStub(
            pollResults: [BurnBarDeviceAuthPollResponse(
                status: .approved,
                credentialEnvelope: goldenEnvelope()
            )]
        )
        let identityClient = IdentityClientStub(baseDate: fixedDate, signInGate: gate)
        let service = try makeService(
            backend: backend,
            deviceClient: deviceClient,
            identityClient: identityClient
        )
        _ = try await service.startDeviceAuthorization()

        let poll = Task { try await service.pollDeviceAuthorization(flowID: flowID) }
        await gate.waitUntilStarted()
        let signedOut = try await service.signOut()
        XCTAssertEqual(signedOut.account.state, .signedOut)
        XCTAssertNil(backend.secret())

        await gate.release()
        let stalePollResult = try await poll.value
        XCTAssertEqual(stalePollResult.account.state, .signedOut)
        XCTAssertNil(backend.secret())
        let finalStatus = await service.status()
        XCTAssertEqual(finalStatus.account.state, .signedOut)
    }

    func testRestartRestoresWithValidatedProductionFirebaseAPIKeyDefault() async throws {
        let events = EventRecorder()
        let backend = RecordingSecretBackend(initialSecret: "persisted-refresh", events: events)
        let identityClient = IdentityClientStub(events: events, baseDate: fixedDate)
        let defaultAPIKey = BurnBarAccountAuthService.resolvedProductionFirebaseAPIKey(environment: [:])
        XCTAssertEqual(defaultAPIKey, BurnBarAccountAuthService.productionFirebaseAPIKey)
        XCTAssertEqual(
            BurnBarAccountAuthService.resolvedProductionFirebaseAPIKey(
                environment: ["OPENBURNBAR_FIREBASE_API_KEY": "not-a-google-api-key"]
            ),
            defaultAPIKey
        )
        let validOverride = "AIza" + String(repeating: "A", count: 35)
        XCTAssertEqual(
            BurnBarAccountAuthService.resolvedProductionFirebaseAPIKey(
                environment: ["OPENBURNBAR_FIREBASE_API_KEY": validOverride]
            ),
            validOverride
        )

        let fixedDate = self.fixedDate
        let service = BurnBarAccountAuthService(
            deviceAuthClient: DeviceAuthClientStub(),
            identityClient: identityClient,
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend])),
            configuredFirebaseAPIKey: defaultAPIKey,
            now: { fixedDate }
        )
        let restored = await service.status()
        XCTAssertEqual(restored.account.state, .signedIn)
        XCTAssertEqual(restored.account.uid, "firebase-user-1")
        XCTAssertEqual(restored.account.syncState, "local_only")
        XCTAssertEqual(backend.secret(), "refresh-token-rotated")
        XCTAssertEqual(events.snapshot(), ["refresh", "store:refresh-token-rotated", "profile"])
        let refreshAPIKey = await identityClient.lastRefreshAPIKey()
        XCTAssertEqual(refreshAPIKey, defaultAPIKey)
    }

    func testConcurrentStatusCallsJoinOnePersistedSessionRestore() async throws {
        let backend = RecordingSecretBackend(initialSecret: "persisted-refresh")
        let identityClient = IdentityClientStub(
            baseDate: fixedDate,
            refreshDelayNanoseconds: 50_000_000
        )
        let fixedDate = self.fixedDate
        let service = BurnBarAccountAuthService(
            deviceAuthClient: DeviceAuthClientStub(),
            identityClient: identityClient,
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend])),
            configuredFirebaseAPIKey: BurnBarAccountAuthService.productionFirebaseAPIKey,
            now: { fixedDate }
        )

        async let accountLoad = service.status()
        async let membershipIdentityLoad = service.status()
        let responses = await [accountLoad, membershipIdentityLoad]
        XCTAssertEqual(responses.map(\.account.state), [.signedIn, .signedIn])
        XCTAssertEqual(responses.map(\.account.uid), ["firebase-user-1", "firebase-user-1"])
        let refreshCount = await identityClient.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testVerificationURLRequiresExactDesktopAuthOriginAndFlow() {
        XCTAssertTrue(EnvironmentBurnBarDeviceAuthCloudClient.isValidVerificationURL(
            URL(string: "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth")!,
            expectedUserCode: "ABCD-EFGH"
        ))
        let rejected = [
            "http://burnbar.ai/link?flow=desktop_auth",
            "https://www.burnbar.ai/link?flow=desktop_auth",
            "https://burnbar.ai:8443/link?flow=desktop_auth",
            "https://user@burnbar.ai/link?flow=desktop_auth",
            "https://burnbar.ai/other?flow=desktop_auth",
            "https://burnbar.ai/link?flow=desktop_auth&flow=desktop_auth",
            "https://burnbar.ai/link?flow=cli",
            "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth&next=https://example.com",
            "https://burnbar.ai/link?flow=desktop_auth#fragment"
        ]
        for raw in rejected {
            XCTAssertFalse(
                EnvironmentBurnBarDeviceAuthCloudClient.isValidVerificationURL(URL(string: raw)!),
                raw
            )
        }
    }

    func testSensitiveHTTPSessionRefusesEveryHTTPRedirectClass() throws {
        let source = URL(string: "https://securetoken.googleapis.com/v1/token?key=fixture")!
        let destination = URL(string: "https://redirect.example/collect")!
        let proposedRequest = URLRequest(url: destination)

        for statusCode in [301, 302, 307, 308] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            ))
            XCTAssertNil(
                BurnBarNoRedirectSessionDelegate.redirectedRequest(
                    for: response,
                    proposedRequest: proposedRequest
                ),
                "HTTP \(statusCode) must never forward a token-bearing request"
            )
        }

        let baseSession = URLSession(configuration: .ephemeral)
        let sensitiveSession = BurnBarSensitiveHTTPSession.wrapping(baseSession)
        XCTAssertTrue(sensitiveSession.delegate is BurnBarNoRedirectSessionDelegate)
        sensitiveSession.invalidateAndCancel()
        baseSession.invalidateAndCancel()
    }

    func testSensitiveHTTPResponseMustMatchTheExactRequestedEndpoint() throws {
        let endpoint = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=fixture")!
        let exact = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let redirected = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://redirect.example/collect")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        XCTAssertTrue(BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(exact, endpoint: endpoint))
        XCTAssertFalse(BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(redirected, endpoint: endpoint))
    }

    func testAccountRPCMethodsHaveDedicatedCapabilityAndCoverageDomain() {
        let methods: [BurnBarRPCMethod] = [
            .accountStatus,
            .accountDeviceAuthStart,
            .accountDeviceAuthPoll,
            .accountDeviceAuthCancel,
            .accountSignOut
        ]
        for method in methods {
            XCTAssertEqual(BurnBarRPCCapability.capability(for: method), .account)
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "account")
        }
    }

    func testAccountRPCHandlerEncodesStatusAndForwardsOpaqueFlowID() async throws {
        let account = AccountServiceStub(flowID: flowID, updatedAt: "2026-07-10T00:00:00Z")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            accountService: account
        )

        let statusData = try await server.handleAccountRPC(
            method: .accountStatus,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"account-status","method":"daemon.account.status"}"#.utf8)
        )
        let status = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarAccountStatusResponse>.self,
            from: statusData
        )
        XCTAssertEqual(status.result?.account.state, .authorizationPending)
        XCTAssertEqual(status.result?.account.session?.flowID, flowID)

        let pollData = try await server.handleAccountRPC(
            method: .accountDeviceAuthPoll,
            decoder: JSONDecoder(),
            requestData: Data("""
            {"id":"account-poll","method":"daemon.account.device_auth.poll","params":{"flow_id":"\(flowID)"}}
            """.utf8)
        )
        let poll = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarAccountStatusResponse>.self,
            from: pollData
        )
        XCTAssertEqual(poll.result?.account.state, .authorizationPending)
        let polledFlowID = await account.polledFlowID()
        XCTAssertEqual(polledFlowID, flowID)
    }

    private func makeService(
        backend: RecordingSecretBackend,
        deviceClient: DeviceAuthClientStub,
        identityClient: IdentityClientStub,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_783_296_000) }
    ) throws -> BurnBarAccountAuthService {
        let privateKey = try LinuxDesktopAuthDeliveryKey(
            rawPrivateKey: XCTUnwrap(Data(base64Encoded: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="))
        )
        return BurnBarAccountAuthService(
            deviceAuthClient: deviceClient,
            identityClient: identityClient,
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend])),
            configuredFirebaseAPIKey: "fixture-public-api-key",
            now: now,
            makeUUID: { UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")! },
            makeDeviceSecret: { String(repeating: "s", count: 64) },
            makeDeliveryKey: { privateKey }
        )
    }

    private func goldenEnvelope() -> LinuxDesktopAuthCredentialEnvelope {
        LinuxDesktopAuthCredentialEnvelope(
            algorithm: "p256-ecdh-aes-256-gcm-v2",
            ephemeralPublicKeyBase64: "BFUPRxAD89+Xw99QaseX9nIfsaH7e49vg9IkSYplyI4kE2CT1wEuUJpzcVy9CwCjzA/0tcAbP/oZarH7MnA2uOY=",
            ivBase64: "AAECAwQFBgcICQoL",
            ciphertextBase64: "WJ1MFaVqLoBVhgpeNaI/Jus3fwj0QvlOgdZ44t7CmiTkTjdKao/EK+ZL6gbbUSfQJ0HRVZzd/DDuizoCFiNmxCAyNmO7meNcXle2a8oJjKkncnuSfxKL7O6YHpnjAHUOrL/b8ffeoZDZ5F1rCy57jKrDUjBmzCwI1la9wWs55YOYqOA0zyhn2OysABVxvyYJsYi0mtSZeF37YQ01qEbT6gNUz/M2240v3p0BCmtCk8DxbM+IdGriztHA",
            authTagBase64: "HttMrV4lkorbCqmy2PKTFQ==",
            aad: "openburnbar:desktop-auth:credential-delivery:v2:\(flowID)"
        )
    }
}

private actor DeviceAuthClientStub: BurnBarDeviceAuthCloudClient {
    private var pollResults: [BurnBarDeviceAuthPollResponse]
    private var startRequest: BurnBarDeviceAuthStartRequest?
    private var currentCancelError: BurnBarAccountAuthError?
    private var cancellations = 0

    init(
        pollResults: [BurnBarDeviceAuthPollResponse] = [],
        cancelError: BurnBarAccountAuthError? = nil
    ) {
        self.pollResults = pollResults
        currentCancelError = cancelError
    }

    func start(_ request: BurnBarDeviceAuthStartRequest) async throws -> BurnBarDeviceAuthStartResponse {
        startRequest = request
        return BurnBarDeviceAuthStartResponse(
            deviceCode: "server-device-code",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth")!,
            pollIntervalSeconds: 5,
            expiresInSeconds: 600
        )
    }

    func poll(deviceCode: String, deviceSecret: String) async throws -> BurnBarDeviceAuthPollResponse {
        guard pollResults.isEmpty == false else {
            return BurnBarDeviceAuthPollResponse(status: .pending, credentialEnvelope: nil)
        }
        return pollResults.removeFirst()
    }

    func cancel(deviceCode: String, deviceSecret: String) async throws {
        cancellations += 1
        if let currentCancelError { throw currentCancelError }
    }

    func recordedStartRequest() -> BurnBarDeviceAuthStartRequest? { startRequest }
    func setCancelError(_ error: BurnBarAccountAuthError?) { currentCancelError = error }
    func cancelCount() -> Int { cancellations }
}

private actor IdentityClientStub: BurnBarFirebaseIdentityClient {
    private let events: EventRecorder?
    private let baseDate: Date
    private let refreshDelayNanoseconds: UInt64
    private let refreshGate: RefreshGate?
    private let signInGate: RefreshGate?
    private let signInError: BurnBarAccountAuthError?
    private var refreshCalls = 0
    private var recordedRefreshAPIKey: String?

    init(
        events: EventRecorder? = nil,
        baseDate: Date,
        refreshDelayNanoseconds: UInt64 = 0,
        refreshGate: RefreshGate? = nil,
        signInGate: RefreshGate? = nil,
        signInError: BurnBarAccountAuthError? = nil
    ) {
        self.events = events
        self.baseDate = baseDate
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.refreshGate = refreshGate
        self.signInGate = signInGate
        self.signInError = signInError
    }

    func signIn(customToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet {
        guard customToken == "fixture-custom-token", apiKey == "fixture-public-api-key" else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        if let signInGate {
            await signInGate.waitForRelease()
        }
        if let signInError { throw signInError }
        return BurnBarFirebaseTokenSet(
            idToken: "id-token-1",
            refreshToken: "refresh-token-1",
            expiresAt: baseDate.addingTimeInterval(3_600),
            localID: "firebase-user-1",
            email: "person@example.com",
            displayName: nil,
            photoURL: nil
        )
    }

    func refresh(refreshToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet {
        refreshCalls += 1
        recordedRefreshAPIKey = apiKey
        events?.append("refresh")
        if refreshDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        if let refreshGate {
            await refreshGate.waitForRelease()
        }
        return BurnBarFirebaseTokenSet(
            idToken: "id-token-rotated",
            refreshToken: "refresh-token-rotated",
            expiresAt: baseDate.addingTimeInterval(7_200),
            localID: "firebase-user-1",
            email: nil,
            displayName: nil,
            photoURL: nil
        )
    }

    func profile(idToken: String, apiKey: String) async throws -> BurnBarFirebaseProfile {
        events?.append("profile")
        return BurnBarFirebaseProfile(
            uid: "firebase-user-1",
            email: "person@example.com",
            displayName: "Linux Person",
            photoURL: "https://burnbar.ai/avatar.png"
        )
    }

    func refreshCount() -> Int { refreshCalls }
    func lastRefreshAPIKey() -> String? { recordedRefreshAPIKey }
}

private actor RefreshGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard released == false else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard started == false else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AccountServiceStub: BurnBarAccountServing {
    private let flowID: String
    private let updatedAt: String
    private var lastPolledFlowID: String?

    init(flowID: String, updatedAt: String) {
        self.flowID = flowID
        self.updatedAt = updatedAt
    }

    func status() async -> BurnBarAccountStatusResponse { response() }
    func startDeviceAuthorization() async throws -> BurnBarAccountStatusResponse { response() }

    func pollDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse {
        lastPolledFlowID = flowID
        return response()
    }

    func cancelDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse { response() }
    func signOut() async throws -> BurnBarAccountStatusResponse { response() }
    func polledFlowID() -> String? { lastPolledFlowID }

    private func response() -> BurnBarAccountStatusResponse {
        BurnBarAccountStatusResponse(account: BurnBarAccountSnapshot(
            state: .authorizationPending,
            session: BurnBarAccountDeviceAuthSession(
                flowID: flowID,
                userCode: "ABCD-EFGH",
                verificationURL: "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth",
                expiresAt: updatedAt,
                pollIntervalSeconds: 5
            ),
            updatedAt: updatedAt
        ))
    }
}

private final class RecordingSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true

    private let lock = NSLock()
    private var storedSecrets: [String: String]
    private var deleteError: LinuxSecretStoreError?
    private let events: EventRecorder?

    init(initialSecret: String? = nil, events: EventRecorder? = nil) {
        storedSecrets = initialSecret.map { ["firebase-refresh-token": $0] } ?? [:]
        self.events = events
    }

    func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedSecret = storedSecrets[id] else { return nil }
        return LinuxSecretRecord(secret: storedSecret, metadata: metadata(id: id, secretClass: secretClass))
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        lock.lock()
        storedSecrets[id] = secret
        lock.unlock()
        if id == "firebase-refresh-token" {
            events?.append("store:\(secret)")
        }
        return metadata(id: id, secretClass: secretClass)
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        lock.lock()
        if let deleteError {
            lock.unlock()
            throw deleteError
        }
        storedSecrets[id] = nil
        lock.unlock()
    }

    func healthCheck() throws {}

    func secret() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedSecrets["firebase-refresh-token"]
    }

    func setDeleteError(_ error: LinuxSecretStoreError?) {
        lock.lock()
        deleteError = error
        lock.unlock()
    }

    private func metadata(id: String, secretClass: LinuxHighValueSecretClass) -> LinuxSecretMetadata {
        LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 1_783_296_000_000,
            note: "test metadata"
        )
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
