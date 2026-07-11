#if os(Linux)
import Foundation
import Glibc
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenBurnBarKernel
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxDaemonCloudCredentialAuthorityTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_900_000_000)

    func testCredentialMintIsSingleFlightBoundAndForceRefreshesIDToken() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow)
        let authority = makeAuthority(backend: backend, transport: transport.transport)

        let contexts = try await withThrowingTaskGroup(of: LinuxIrohControllerCredentialContext.self) { group in
            for _ in 0..<12 { group.addTask { try await authority.credentialContext() } }
            var values: [LinuxIrohControllerCredentialContext] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(contexts.map(\.idToken)), ["firebase-id-bound"])
        XCTAssertEqual(Set(contexts.map(\.appCheckToken)), ["app-check-live"])
        XCTAssertEqual(Set(contexts.map(\.deviceID)).count, 1)
        XCTAssertTrue(contexts[0].deviceID.hasPrefix("linux_"))
        XCTAssertEqual(contexts[0].deviceID.count, 70)
        let requestPaths = await transport.paths()
        XCTAssertEqual(requestPaths, [
            "/v1/token", "/registerLinuxAppCheckDevice", "/issueLinuxAppCheckChallenge",
            "/mintLinuxAppCheckToken", "/bindAppCheckAttestation", "/v1/token"
        ])
        XCTAssertEqual(backend.secret(id: "firebase-refresh-token"), "refresh-bound")
        XCTAssertFalse(backend.allSecrets().values.contains("firebase-id-bound"))
        XCTAssertFalse(backend.allSecrets().values.contains("app-check-live"))

        let encodedStatus = try JSONEncoder().encode(await authority.status())
        let statusText = String(decoding: encodedStatus, as: UTF8.self)
        XCTAssertFalse(statusText.contains(contexts[0].uid))
        XCTAssertFalse(statusText.contains(contexts[0].deviceID))
        XCTAssertFalse(statusText.contains("firebase-id-bound"))
        XCTAssertFalse(statusText.contains("app-check-live"))
    }

    func testSignOutInvalidatesRefreshInFlightAndStopsBeforeMint() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let gate = CloudAuthRefreshGate(now: fixedNow)
        let authority = makeAuthority(backend: backend, transport: gate.transport)
        let tasks = (0..<12).map { _ in
            Task { () -> LinuxCloudAuthAuthorityError? in
                do {
                    _ = try await authority.credentialContext()
                    return nil
                } catch let error as LinuxCloudAuthAuthorityError {
                    return error
                } catch {
                    return .cloudUnavailable
                }
            }
        }
        await gate.waitUntilRequested()
        for _ in 0..<32 { await Task.yield() }

        try await authority.signOut()
        await gate.release()

        for task in tasks {
            let error = await task.value
            XCTAssertNotNil(error, "A signed-out generation must not publish credentials")
            XCTAssertTrue(error == .sessionChanged || error == .notSignedIn)
        }
        XCTAssertNil(backend.secret(id: "firebase-refresh-token"))
        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 1)
        let status = await authority.status()
        XCTAssertEqual(status.state, .signedOut)
        XCTAssertFalse(status.signedIn)
    }

    func testStaleRefreshFailureCannotOverwriteSignedOutStatus() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let gate = CloudAuthRefreshGate(now: fixedNow, failAfterRelease: true)
        let authority = makeAuthority(backend: backend, transport: gate.transport)
        let task = Task { try await authority.credentialContext() }
        await gate.waitUntilRequested()

        try await authority.signOut()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("A stale refresh failure must not publish credentials")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .sessionChanged)
        }
        let status = await authority.status()
        XCTAssertEqual(status.state, .signedOut)
        XCTAssertEqual(status.detail, nil)
    }

    func testSignOutLifecycleReentryCannotRemintOrResurrectSession() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow)
        let authority = makeAuthority(backend: backend, transport: transport.transport)
        _ = try await authority.credentialContext()
        let pathsBeforeSignOut = await transport.paths()
        let probe = CloudAuthLifecycleProbe()
        await authority.setLifecycleHandler { event in
            guard event == .invalidated else { return }
            do {
                _ = try await authority.credentialContext()
                await probe.record(nil)
            } catch let error as LinuxCloudAuthAuthorityError {
                await probe.record(error)
            } catch {
                await probe.record(.cloudUnavailable)
            }
        }

        try await authority.signOut()

        let reentryError = await probe.error()
        let pathsAfterSignOut = await transport.paths()
        XCTAssertEqual(reentryError, .sessionChanged)
        XCTAssertEqual(pathsAfterSignOut, pathsBeforeSignOut)
        do {
            _ = try await authority.credentialContext()
            XCTFail("Post-sign-out credential acquisition must fail")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    func testStatusPollingDoesNotReadRefreshTokenBytes() async {
        let backend = CloudAuthMutableSecretBackend(refreshToken: nil)
        let authority = makeAuthority(backend: backend) { _, _ in throw URLError(.notConnectedToInternet) }
        let readsAfterInitialization = backend.readCount()
        for _ in 0..<20 { _ = await authority.status() }
        XCTAssertEqual(backend.readCount(), readsAfterInitialization)
    }

    func testBoundedHTTPTransportCancellationAbortsLiveURLSession() async throws {
        cloudAuthURLProtocolProbe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAuthHangingURLProtocol.self]
        let delegate = LinuxCloudAuthBoundedDataDelegate(
            configuration: configuration,
            maximumBytes: 1_024
        )
        let request = URLRequest(url: URL(string: "https://example.invalid/hang")!)
        let task = Task { () -> Bool in
            do {
                _ = try await delegate.perform(request)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await cloudAuthURLProtocolProbe.waitForStart()
        task.cancel()
        let cancelled = await task.value
        await cloudAuthURLProtocolProbe.waitForStop()
        let counts = cloudAuthURLProtocolProbe.snapshot()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testAccountSwitchTearsDownWithOldSnapshotBeforeMintingNewAccount() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow, switchedUID: "user-B")
        let authority = makeAuthority(backend: backend, transport: transport.transport)
        let oldContext = try await authority.credentialContext()
        let teardown = CloudAuthTeardownGate()
        await authority.setTeardownHandler { credentials in
            await teardown.handle(credentials)
        }

        let begin = try await authority.beginSignIn()
        let callbackStatus = try await browserCallbackStatus(begin)
        XCTAssertEqual(callbackStatus, 200)
        await teardown.waitUntilEntered()

        let teardownContext = await teardown.firstContext()
        let pathsDuringTeardown = await transport.paths()
        XCTAssertEqual(teardownContext?.uid, oldContext.uid)
        XCTAssertEqual(teardownContext?.sessionGeneration, oldContext.sessionGeneration)
        XCTAssertEqual(pathsDuringTeardown.suffix(2), ["/token", "/v1/accounts:signInWithIdp"])

        await teardown.release()
        let readyStatus = await waitForAuthState(.active, authority: authority)
        XCTAssertEqual(readyStatus.state, .active)
        let newContext = try await authority.credentialContext()
        XCTAssertEqual(newContext.uid, "user-B")
        XCTAssertGreaterThan(newContext.sessionGeneration, oldContext.sessionGeneration)
    }

    func testSignOutDuringAccountSwitchTeardownCannotResurrectNewAccount() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow, switchedUID: "user-B")
        let authority = makeAuthority(backend: backend, transport: transport.transport)
        _ = try await authority.credentialContext()
        let teardown = CloudAuthTeardownGate()
        await authority.setTeardownHandler { credentials in
            await teardown.handle(credentials)
        }

        let begin = try await authority.beginSignIn()
        let callbackStatus = try await browserCallbackStatus(begin)
        XCTAssertEqual(callbackStatus, 200)
        await teardown.waitUntilEntered()
        try await authority.signOut()
        await teardown.release()
        for _ in 0..<64 { await Task.yield() }

        let status = await authority.status()
        XCTAssertEqual(status.state, .signedOut)
        XCTAssertNil(backend.secret(id: "firebase-refresh-token"))
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == "/mintLinuxAppCheckToken" }.count, 1)
        do {
            _ = try await authority.credentialContext()
            XCTFail("The interrupted account switch must remain signed out")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    func testFailedAccountSwitchRetainsReadyOldAccount() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow, failGoogleExchange: true)
        let authority = makeAuthority(backend: backend, transport: transport.transport)
        let oldContext = try await authority.credentialContext()

        let begin = try await authority.beginSignIn()
        let callbackStatus = try await browserCallbackStatus(begin)
        XCTAssertEqual(callbackStatus, 200)
        let status = await waitForAuthState(.active, authority: authority)
        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.detail, "cloud_unavailable")
        let retainedContext = try await authority.credentialContext()
        XCTAssertEqual(retainedContext, oldContext)
    }

    func testMalformedRefreshFailsClosedWithoutPersistingResponseTokens() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let authority = makeAuthority(backend: backend) { request, _ in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        do {
            _ = try await authority.credentialContext()
            XCTFail("Malformed Firebase JSON must fail closed")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .cloudUnavailable)
        }
        XCTAssertEqual(backend.secret(id: "firebase-refresh-token"), "refresh-initial")
        let status = await authority.status()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.detail, "cloud_unavailable")
    }

    func testExpiredAppCheckChallengeFailsBeforeMintOrBind() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow, expiredChallenge: true)
        let authority = makeAuthority(backend: backend, transport: transport.transport)

        do {
            _ = try await authority.credentialContext()
            XCTFail("An expired device challenge must fail closed")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .cloudUnavailable)
        }

        let requestPaths = await transport.paths()
        XCTAssertEqual(requestPaths, [
            "/v1/token", "/registerLinuxAppCheckDevice", "/issueLinuxAppCheckChallenge"
        ])
        XCTAssertFalse(requestPaths.contains("/mintLinuxAppCheckToken"))
        XCTAssertFalse(requestPaths.contains("/bindAppCheckAttestation"))
    }

    func testAppCheckTTLAboveThirtyMinutesFailsBeforeBind() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: "refresh-initial")
        let transport = CloudAuthScriptedTransport(now: fixedNow, appCheckTTLMillis: 1_800_001)
        let authority = makeAuthority(backend: backend, transport: transport.transport)

        do {
            _ = try await authority.credentialContext()
            XCTFail("Linux lower-trust App Check TTL must not exceed 30 minutes")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .cloudUnavailable)
        }

        let requestPaths = await transport.paths()
        XCTAssertTrue(requestPaths.contains("/mintLinuxAppCheckToken"))
        XCTAssertFalse(requestPaths.contains("/bindAppCheckAttestation"))
    }

    func testSecureStoreFailureIsRedactedAndFailsClosed() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: nil, readFailure: true)
        let authority = makeAuthority(backend: backend) { _, _ in XCTFail("network must not run"); throw URLError(.badURL) }
        do {
            _ = try await authority.credentialContext()
            XCTFail("Locked SecretStore must fail closed")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .secureStoreUnavailable)
        }
        let status = await authority.status()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.detail, "secure_store_unavailable")
    }

    func testDaemonLoggerRedactsFirebaseAndAuthorizationCredentials() {
        let input = "Authorization: Bearer abc.def.ghi id_token=eyJheader.payload.signature api_key=AIza1234567890abcdefghijkl"
        let output = BurnBarDaemonLogger.redactedMetadataValue(input)
        XCTAssertFalse(output.contains("abc.def.ghi"))
        XCTAssertFalse(output.contains("eyJheader"))
        XCTAssertFalse(output.contains("AIza"))
        XCTAssertTrue(output.contains("[REDACTED]"))
        XCTAssertFalse(output.contains("\n"))
    }

    func testShippingServerExposesRedactedAuthorityStatus() async throws {
        let backend = CloudAuthMutableSecretBackend(refreshToken: nil)
        let authority = makeAuthority(backend: backend) { _, _ in throw URLError(.notConnectedToInternet) }
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: "/tmp/openburnbar-auth-composition-\(UUID().uuidString).sock"),
            linuxCloudCredentialAuthority: authority
        )
        let status = await server.linuxCloudAuthStatus()
        XCTAssertEqual(status.state, .signedOut)
        XCTAssertFalse(status.signedIn)
        XCTAssertNil(status.identityLabel)
    }

    func testProductionConfigurationAcceptsOnlyPrivateExplicitRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cloud-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("cloud-auth.json")
        let json = #"{"schemaVersion":1,"configured":true,"googleOAuthClientID":"123456789012.apps.googleusercontent.com","firebaseAPIKey":"AIza1234567890abcdefghij","linuxAppCheckAppID":"1:123456789:linux:abcdef123456"}"#
        try Data(json.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let configuration = LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE": configURL.path
        ])
        XCTAssertEqual(configuration?.googleOAuthClientID, "123456789012.apps.googleusercontent.com")
        XCTAssertEqual(configuration?.firebaseAPIKey, "AIza1234567890abcdefghij")
        XCTAssertEqual(configuration?.linuxAppCheckAppID, "1:123456789:linux:abcdef123456")

        let packagedURL = directory.appendingPathComponent("cloud-auth-packaged.json")
        try Data(json.utf8).write(to: packagedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: packagedURL.path)
        let packagedConfiguration = LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE": packagedURL.path
        ])
        if geteuid() == 0 {
            XCTAssertEqual(packagedConfiguration, configuration)
        } else {
            XCTAssertNil(packagedConfiguration)
        }

        let symlinkURL = directory.appendingPathComponent("cloud-auth-link.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: configURL)
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE": symlinkURL.path
        ]))

        let unconfiguredURL = directory.appendingPathComponent("cloud-auth-unconfigured.json")
        try Data(#"{"schemaVersion":1,"configured":false}"#.utf8).write(to: unconfiguredURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unconfiguredURL.path)
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE": unconfiguredURL.path
        ]))

        let unknownKeyURL = directory.appendingPathComponent("cloud-auth-unknown-key.json")
        try Data(#"{"schemaVersion":1,"configured":false,"unexpected":true}"#.utf8).write(to: unknownKeyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknownKeyURL.path)
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE": unknownKeyURL.path
        ]))

        let wrongSchemaURL = directory.appendingPathComponent("cloud-auth-wrong-schema.json")
        try Data(#"{"schemaVersion":2,"configured":true,"googleOAuthClientID":"123456789012.apps.googleusercontent.com","firebaseAPIKey":"AIza1234567890abcdefghij","linuxAppCheckAppID":"1:123456789:linux:abcdef123456"}"#.utf8).write(to: wrongSchemaURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wrongSchemaURL.path)
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE": wrongSchemaURL.path
        ]))
    }

    func testProductionConfigurationRejectsPartialEnvironmentAndPlaceholders() throws {
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_FIREBASE_API_KEY": "firebase-api-key"
        ]))
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID": "YOUR_CLIENT_ID",
            "OPENBURNBAR_FIREBASE_API_KEY": "firebase-api-key",
            "OPENBURNBAR_LINUX_APP_CHECK_APP_ID": "1:123:linux:abcdef"
        ]))
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID": "123456789012.example.com",
            "OPENBURNBAR_FIREBASE_API_KEY": "AIza1234567890abcdefghij",
            "OPENBURNBAR_LINUX_APP_CHECK_APP_ID": "1:123456789:linux:abcdef123456"
        ]))
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID": "123456789012.apps.googleusercontent.com",
            "OPENBURNBAR_FIREBASE_API_KEY": "AIza-short",
            "OPENBURNBAR_LINUX_APP_CHECK_APP_ID": "1:123456789:linux:abcdef123456"
        ]))
        XCTAssertNil(LinuxCloudAuthConfiguration.production(environment: [
            "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID": "123456789012.apps.googleusercontent.com",
            "OPENBURNBAR_FIREBASE_API_KEY": "AIza1234567890abcdefghij",
            "OPENBURNBAR_LINUX_APP_CHECK_APP_ID": "1:123:web:short"
        ]))
    }

    private func makeAuthority(
        backend: CloudAuthMutableSecretBackend,
        transport: @escaping LinuxCloudAuthHTTPTransport
    ) -> LinuxDaemonCloudCredentialAuthority {
        let fixedNow = fixedNow
        return LinuxDaemonCloudCredentialAuthority(
            configuration: LinuxCloudAuthConfiguration(
                googleOAuthClientID: "123456789012.apps.googleusercontent.com",
                firebaseAPIKey: "AIza1234567890abcdefghij",
                linuxAppCheckAppID: "1:123456789:linux:abcdef123456"
            ),
            custodian: LinuxSecretCustodian(backends: [backend]),
            httpTransport: transport,
            now: { fixedNow },
            hostname: "linux-test-host"
        )
    }

    private func browserCallbackStatus(_ begin: BurnBarLinuxAuthBeginResponse) async throws -> Int {
        let authorizationURL = try XCTUnwrap(URL(string: begin.authorizationURL))
        let items = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try XCTUnwrap(items.first(where: { $0.name == "state" })?.value)
        let redirect = try XCTUnwrap(items.first(where: { $0.name == "redirect_uri" })?.value)
        var callback = try XCTUnwrap(URLComponents(string: redirect))
        callback.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: state)
        ]
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(callback.url))
        return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    }

    private func waitForAuthState(
        _ state: BurnBarLinuxAuthState,
        authority: LinuxDaemonCloudCredentialAuthority
    ) async -> BurnBarLinuxAuthStatusResponse {
        for _ in 0..<2_000 {
            let status = await authority.status()
            if status.state == state { return status }
            await Task.yield()
        }
        return await authority.status()
    }
}

final class LinuxOAuthLoopbackListenerTests: XCTestCase {
    func testWrongStateProbeCannotConsumeFollowingValidCallback() async throws {
        let listener = try LinuxOAuthLoopbackListener(expectedState: "expected-state")
        let wait = Task { try await listener.waitForCallback(timeout: 2) }
        let wrongStatus = try await callbackStatus(
            port: listener.port,
            query: "code=probe&state=wrong-state"
        )
        XCTAssertEqual(wrongStatus, 400)
        let validStatus = try await callbackStatus(
            port: listener.port,
            query: "code=authorization-code&state=expected-state"
        )
        XCTAssertEqual(validStatus, 200)
        let callback = try await wait.value
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, "authorization-code")
    }

    func testAccessDeniedCancelsListenerWithoutReportingSuccess() async throws {
        let listener = try LinuxOAuthLoopbackListener(expectedState: "expected-state")
        let wait = Task { try await listener.waitForCallback(timeout: 2) }
        let status = try await callbackStatus(
            port: listener.port,
            query: "error=access_denied&state=expected-state"
        )
        XCTAssertEqual(status, 400)
        do {
            _ = try await wait.value
            XCTFail("access_denied must cancel browser authorization")
        } catch let error as LinuxOAuthLoopbackError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testExplicitCancellationAndTimeoutFailClosed() async throws {
        let cancelled = try LinuxOAuthLoopbackListener(expectedState: "expected-state")
        let cancelledWait = Task { try await cancelled.waitForCallback(timeout: 2) }
        cancelled.cancel()
        do {
            _ = try await cancelledWait.value
            XCTFail("Cancelled listener must not return a callback")
        } catch let error as LinuxOAuthLoopbackError {
            XCTAssertEqual(error, .cancelled)
        }

        let timedOut = try LinuxOAuthLoopbackListener(expectedState: "expected-state")
        do {
            _ = try await timedOut.waitForCallback(timeout: 0.01)
            XCTFail("Idle listener must time out")
        } catch let error as LinuxOAuthLoopbackError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    private func callbackStatus(port: Int, query: String) async throws -> Int {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/callback?\(query)"))
        let (_, response) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    }
}

private final class CloudAuthMutableSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true
    private let lock = NSLock()
    private var records: [String: String]
    private var reads = 0
    private let readFailure: Bool

    init(refreshToken: String?, readFailure: Bool = false) {
        records = refreshToken.map { ["firebase-refresh-token": $0] } ?? [:]
        self.readFailure = readFailure
    }

    func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        lock.withLock { reads += 1 }
        if readFailure { throw LinuxSecretStoreError.backendUnavailable("locked") }
        return lock.withLock {
            records[id].map {
                LinuxSecretRecord(secret: $0, metadata: LinuxSecretMetadata(
                    id: id, secretClass: secretClass, trustLevel: trustLevel,
                    backend: backendName, createdAtMillis: 1_900_000_000_000, note: "test"
                ))
            }
        }
    }

    func storeSecret(_ secret: String, id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretMetadata {
        lock.withLock { records[id] = secret }
        return LinuxSecretMetadata(
            id: id, secretClass: secretClass, trustLevel: trustLevel,
            backend: backendName, createdAtMillis: 1_900_000_000_000, note: "test"
        )
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        _ = lock.withLock { records.removeValue(forKey: id) }
    }

    func healthCheck() throws {}
    func secret(id: String) -> String? { lock.withLock { records[id] } }
    func allSecrets() -> [String: String] { lock.withLock { records } }
    func readCount() -> Int { lock.withLock { reads } }
}

private actor CloudAuthLifecycleProbe {
    private var recordedError: LinuxCloudAuthAuthorityError?
    func record(_ error: LinuxCloudAuthAuthorityError?) { recordedError = error }
    func error() -> LinuxCloudAuthAuthorityError? { recordedError }
}

private final class CloudAuthURLProtocolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    func reset() { lock.withLock { starts = 0; stops = 0 } }
    func started() { lock.withLock { starts += 1 } }
    func stopped() { lock.withLock { stops += 1 } }
    func snapshot() -> (starts: Int, stops: Int) { lock.withLock { (starts, stops) } }
    func waitForStart() async { while snapshot().starts == 0 { await Task.yield() } }
    func waitForStop() async { while snapshot().stops == 0 { await Task.yield() } }
}

private let cloudAuthURLProtocolProbe = CloudAuthURLProtocolProbe()

private final class CloudAuthHangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { cloudAuthURLProtocolProbe.started() }
    override func stopLoading() { cloudAuthURLProtocolProbe.stopped() }
}

private actor CloudAuthTeardownGate {
    private var contexts: [LinuxIrohControllerCredentialContext?] = []
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func handle(_ context: LinuxIrohControllerCredentialContext?) async {
        contexts.append(context)
        guard contexts.count == 1 else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while entered == false { await Task.yield() }
    }

    func firstContext() -> LinuxIrohControllerCredentialContext? {
        contexts.first ?? nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CloudAuthScriptedTransport {
    private let now: Date
    private let expiredChallenge: Bool
    private let appCheckTTLMillis: Int64
    private let switchedUID: String?
    private let failGoogleExchange: Bool
    private var requestPaths: [String] = []
    private var refreshCount = 0

    init(
        now: Date,
        expiredChallenge: Bool = false,
        appCheckTTLMillis: Int64 = 1_800_000,
        switchedUID: String? = nil,
        failGoogleExchange: Bool = false
    ) {
        self.now = now
        self.expiredChallenge = expiredChallenge
        self.appCheckTTLMillis = appCheckTTLMillis
        self.switchedUID = switchedUID
        self.failGoogleExchange = failGoogleExchange
    }

    nonisolated var transport: LinuxCloudAuthHTTPTransport {
        { [weak self] request, maximumBytes in
            guard let self else { throw URLError(.cancelled) }
            return try await self.respond(request: request, maximumBytes: maximumBytes)
        }
    }

    func paths() -> [String] { requestPaths }

    private func respond(request: URLRequest, maximumBytes: Int) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        requestPaths.append(url.path)
        let body: String
        switch url.path {
        case "/token":
            if failGoogleExchange { throw URLError(.cannotConnectToHost) }
            body = #"{"id_token":"google-id-token"}"#
        case "/v1/accounts:signInWithIdp":
            let uid = switchedUID ?? "user-B"
            body = #"{"localId":"\#(uid)","idToken":"firebase-id-B","refreshToken":"refresh-B","expiresIn":"3600"}"#
        case "/v1/token":
            let requestBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if requestBody.contains("refresh-B") {
                body = #"{"user_id":"user-B","id_token":"firebase-id-B-bound","refresh_token":"refresh-B-bound","expires_in":"3600"}"#
                break
            }
            refreshCount += 1
            body = refreshCount == 1
                ? #"{"user_id":"user-123","id_token":"firebase-id-initial","refresh_token":"refresh-initial-rotated","expires_in":"3600"}"#
                : #"{"user_id":"user-123","id_token":"firebase-id-bound","refresh_token":"refresh-bound","expires_in":"3600"}"#
        case "/registerLinuxAppCheckDevice", "/bindAppCheckAttestation":
            body = #"{"result":{"ok":true}}"#
        case "/issueLinuxAppCheckChallenge":
            let payload = Data("challenge-payload".utf8).base64EncodedString()
            let current = Int64(now.timeIntervalSince1970 * 1_000)
            let issued = expiredChallenge ? current - 120_000 : current
            let expires = expiredChallenge ? current - 1 : issued + 120_000
            body = #"{"result":{"ok":true,"challengeId":"challenge-1","canonicalPayloadBase64":"\#(payload)","signatureAlgorithm":"ed25519","issuedAtMillis":\#(issued),"expiresAtMillis":\#(expires)}}"#
        case "/mintLinuxAppCheckToken":
            body = #"{"result":{"ok":true,"appCheckToken":"app-check-live","ttlMillis":\#(appCheckTTLMillis),"appId":"1:123456789:linux:abcdef123456","trustClass":"linux_lower_trust"}}"#
        default:
            throw URLError(.unsupportedURL)
        }
        let data = Data(body.utf8)
        XCTAssertLessThanOrEqual(data.count, maximumBytes)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor CloudAuthRefreshGate {
    private let now: Date
    private let failAfterRelease: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested = false
    private var count = 0

    init(now: Date, failAfterRelease: Bool = false) {
        self.now = now
        self.failAfterRelease = failAfterRelease
    }

    nonisolated var transport: LinuxCloudAuthHTTPTransport {
        { [weak self] request, _ in
            guard let self else { throw URLError(.cancelled) }
            return try await self.respond(request)
        }
    }

    func waitUntilRequested() async {
        while requested == false { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func requestCount() -> Int { count }

    private func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        requested = true
        await withCheckedContinuation { continuation = $0 }
        if failAfterRelease { throw URLError(.cannotConnectToHost) }
        let data = Data(#"{"user_id":"user-123","id_token":"firebase-id","refresh_token":"refresh-next","expires_in":"3600"}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
