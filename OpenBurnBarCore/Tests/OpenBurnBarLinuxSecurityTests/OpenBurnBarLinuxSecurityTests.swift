import Foundation
@testable import OpenBurnBarLinuxSecurity
import XCTest
#if os(Linux)
import Glibc
#endif

final class OpenBurnBarLinuxSecurityTests: XCTestCase {
    func testNativeSecretServiceCRUDKeepsSecretOutOfArguments() throws {
        let harness = LinuxSecretCommandHarness(kind: .secretService)
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            nowMillis: { 1_900_000_000_000 },
            runner: { executableURL, arguments, standardInput in
                try harness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        let custodian = LinuxSecretCustodian(backends: [backend])

        let metadata = try custodian.storeHighValueSecret(
            "provider-secret-value",
            id: "com.openburnbar.provider:provider.anthropic.apiKey",
            secretClass: .providerCredential
        )
        XCTAssertEqual(metadata.backend, "org.freedesktop.secrets")
        XCTAssertEqual(metadata.trustLevel, .secretService)

        let restored = try custodian.requireHighValueSecret(
            id: "com.openburnbar.provider:provider.anthropic.apiKey",
            secretClass: .providerCredential
        )
        XCTAssertEqual(restored.secret, "provider-secret-value")
        XCTAssertFalse(harness.arguments.flatMap { $0 }.contains("provider-secret-value"))
        XCTAssertEqual(harness.lastStandardInput, "provider-secret-value\n")

        try custodian.deleteHighValueSecret(
            id: "com.openburnbar.provider:provider.anthropic.apiKey",
            secretClass: .providerCredential
        )
        XCTAssertThrowsError(
            try custodian.requireHighValueSecret(
                id: "com.openburnbar.provider:provider.anthropic.apiKey",
                secretClass: .providerCredential
            )
        ) { error in
            XCTAssertEqual(error as? LinuxSecretStoreError, .missingSecret("com.openburnbar.provider:provider.anthropic.apiKey"))
        }
    }

    func testSecretServiceHealthCheckAcceptsMissingProbeItemOnFreshKeyring() throws {
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { _, arguments, _ in
                XCTAssertEqual(arguments, ["search", "openburnbar-health", "probe"])
                return LinuxSecretCommandResult(exitCode: 1, stderr: "No such secret")
            }
        )

        XCTAssertNoThrow(try backend.healthCheck())
    }

    func testSecretServiceHealthCheckStillFailsForLockedOrUnavailableBackend() throws {
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { _, _, _ in
                LinuxSecretCommandResult(exitCode: 1, stderr: "The Secret Service is locked")
            }
        )

        XCTAssertThrowsError(try backend.healthCheck()) { error in
            guard case let LinuxSecretStoreError.commandFailed(backend, operation, detail) = error else {
                return XCTFail("Expected a command failure, got \(error)")
            }
            XCTAssertEqual(backend, "org.freedesktop.secrets")
            XCTAssertEqual(operation, "health-check")
            XCTAssertEqual(detail, "The Secret Service is locked")
        }
    }

    func testKWalletCRUDUsesFolderEntryAndStdinContract() throws {
        let harness = LinuxSecretCommandHarness(kind: .kwallet)
        let backend = LinuxNativeSecretStoreBackend(
            kind: .kwallet,
            executableURL: URL(fileURLWithPath: "/usr/bin/kwallet-query"),
            walletName: "kdewallet6",
            folderName: "OpenBurnBar",
            runner: { executableURL, arguments, standardInput in
                try harness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )

        _ = try backend.storeSecret(
            "connector-secret",
            id: "connector.home-assistant.credential",
            secretClass: .connectorCredential
        )
        XCTAssertEqual(
            harness.arguments.last,
            ["-f", "OpenBurnBar", "-w", "connector.home-assistant.credential", "kdewallet6"]
        )
        XCTAssertFalse(harness.arguments.last?.contains("connector-secret") ?? true)
        XCTAssertEqual(
            try backend.readSecret(
                id: "connector.home-assistant.credential",
                secretClass: .connectorCredential
            )?.secret,
            "connector-secret"
        )
        try backend.deleteSecret(
            id: "connector.home-assistant.credential",
            secretClass: .connectorCredential
        )
        XCTAssertNil(
            try backend.readSecret(
                id: "connector.home-assistant.credential",
                secretClass: .connectorCredential
            )
        )
    }

    func testNativeBackendRoundTripsSignificantWhitespaceWithoutPuttingItInArguments() throws {
        let harness = LinuxSecretCommandHarness(kind: .secretService)
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { executableURL, arguments, standardInput in
                try harness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        let secret = "  significant leading and trailing whitespace  "

        _ = try backend.storeSecret(secret, id: "whitespace", secretClass: .providerCredential)

        XCTAssertEqual(
            try backend.readSecret(id: "whitespace", secretClass: .providerCredential)?.secret,
            secret
        )
        XCTAssertEqual(harness.lastStandardInput, secret + "\n")
        XCTAssertFalse(harness.arguments.flatMap { $0 }.contains(secret))
    }

    func testNativeBackendRejectsValuesTheLineProtocolCannotRoundTrip() throws {
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { _, _, _ in LinuxSecretCommandResult(exitCode: 0) }
        )

        for invalid in ["line-one\nline-two", "line-one\rline-two", "nul\0value"] {
            XCTAssertThrowsError(
                try backend.storeSecret(invalid, id: "invalid", secretClass: .providerCredential)
            ) { error in
                guard case LinuxSecretStoreError.invalidSecretValue = error else {
                    return XCTFail("Expected invalidSecretValue, got \(error)")
                }
            }
        }
    }

    func testHeadlessEnvironmentSecretsRequireExplicitTestOrDevOptIn() throws {
        let environment = ["OPENBURNBAR_DATABASE_KEY": "plaintext-process-secret"]
        let production = LinuxHeadlessSecretStoreBackend(environment: environment)
        XCTAssertNil(try production.readSecret(id: "database-key", secretClass: .databaseKey))

        let explicit = LinuxHeadlessSecretStoreBackend(
            environment: environment,
            allowsEnvironmentSecrets: true
        )
        XCTAssertEqual(
            try explicit.readSecret(id: "database-key", secretClass: .databaseKey)?.secret,
            "plaintext-process-secret"
        )
    }

    func testSecretStoreTrustMetadataAndNoPlaintextFallbackForHighValueSecrets() throws {
        let secretService = LinuxInMemorySecretStoreBackend(
            backendName: "org.freedesktop.secrets.test",
            trustLevel: .secretService,
            secrets: [
                "database-key": "db-secret-value",
                "signal-identity": "signal-secret-value"
            ]
        )
        let kwallet = LinuxCommandSecretStoreBackend(
            backendName: "kwallet-query",
            trustLevel: .kwallet,
            commandPreview: "kwallet-query openburnbar",
            runner: { id in id == "cloud-vault-key" ? "cloud-vault-secret" : nil }
        )
        let custodian = LinuxSecretCustodian(backends: [secretService, kwallet])

        let database = try custodian.requireHighValueSecret(id: "database-key", secretClass: .databaseKey)
        XCTAssertEqual(database.metadata.trustLevel, .secretService)
        XCTAssertEqual(database.metadata.backend, "org.freedesktop.secrets.test")
        XCTAssertEqual(database.metadata.secretClass, .databaseKey)

        let cloudVault = try custodian.requireHighValueSecret(id: "cloud-vault-key", secretClass: .cloudVaultKey)
        XCTAssertEqual(cloudVault.metadata.trustLevel, .kwallet)
        XCTAssertTrue(cloudVault.metadata.note.contains("kwallet-query"))

        for secretClass in LinuxHighValueSecretClass.allCases {
            let plaintextBackend = LinuxInMemorySecretStoreBackend(
                backendName: "plain-file-fixture",
                trustLevel: .explicitLowerTrustFile,
                secrets: [secretClass.rawValue: "do-not-store-in-file"]
            )
            let plaintextCustodian = LinuxSecretCustodian(backends: [plaintextBackend])
            XCTAssertThrowsError(
                try plaintextCustodian.requireHighValueSecret(id: secretClass.rawValue, secretClass: secretClass)
            ) { error in
                XCTAssertEqual(error as? LinuxSecretStoreError, .plaintextFallbackRefused(secretClass: secretClass))
            }
        }
    }

    func testHeadlessSecretStoreReadsEnvAndSystemdCredentialMetadata() throws {
        let envStore = LinuxHeadlessSecretStoreBackend(
            environment: ["OPENBURNBAR_FIREBASE_REFRESH_TOKEN": "refresh-token-value"],
            allowsEnvironmentSecrets: true
        )
        let envCustodian = LinuxSecretCustodian(backends: [envStore])
        let envToken = try envCustodian.requireHighValueSecret(
            id: "firebase-refresh-token",
            secretClass: .refreshToken
        )
        XCTAssertEqual(envToken.metadata.trustLevel, .headlessPassphrase)
        XCTAssertEqual(envToken.metadata.backend, "headless")

        let fileStore = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { path in
                XCTAssertEqual(path, "/run/credentials/openburnbar.service/audit-signing-key")
                return "audit-secret\n"
            }
        )
        let fileCustodian = LinuxSecretCustodian(backends: [fileStore])
        let auditKey = try fileCustodian.requireHighValueSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        XCTAssertEqual(auditKey.metadata.trustLevel, .systemdCredential)
        XCTAssertTrue(auditKey.metadata.note.contains("systemd credential file"))
    }

    func testHeadlessCredentialBoundaryRejectsTraversalAndMultilineValues() throws {
        let calls = StringArrayCaptureBox()
        let store = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { path in
                calls.append(path)
                return "  systemd-secret  \n"
            }
        )

        let record = try store.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        XCTAssertEqual(record?.secret, "  systemd-secret  ")
        XCTAssertEqual(record?.metadata.trustLevel, .systemdCredential)
        XCTAssertEqual(record?.metadata.note.contains("owner-only"), true)

        for invalidID in ["../outside", "nested/name", "/absolute", "..", ".", "line\nbreak"] {
            XCTAssertThrowsError(
                try store.readSecret(id: invalidID, secretClass: .auditSigningKey)
            ) { error in
                XCTAssertEqual(error as? LinuxSecretStoreError, .invalidSecretID(invalidID))
            }
        }
        XCTAssertEqual(calls.values.count, 1)

        let malformed = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { _ in "line-one\nline-two" }
        )
        XCTAssertThrowsError(
            try malformed.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        ) { error in
            guard case .invalidSecretValue = error as? LinuxSecretStoreError else {
                return XCTFail("Expected invalidSecretValue, got \(error)")
            }
        }
    }

#if os(Linux)
    func testSystemdCredentialReaderRequiresOwnerOnlyRegularFilesAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-systemd-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(root.path.withCString { Glibc.chmod($0, 0o700) }, 0)

        let credential = root.appendingPathComponent("audit-signing-key")
        try Data("audit-secret\n".utf8).write(to: credential)
        XCTAssertEqual(credential.path.withCString { Glibc.chmod($0, 0o600) }, 0)
        let store = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": root.path]
        )
        XCTAssertEqual(
            try store.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)?.secret,
            "audit-secret"
        )

        XCTAssertEqual(credential.path.withCString { Glibc.chmod($0, 0o640) }, 0)
        XCTAssertThrowsError(
            try store.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        ) { error in
            guard case let .backendUnavailable(reason) = error as? LinuxSecretStoreError else {
                return XCTFail("Expected backendUnavailable, got \(error)")
            }
            XCTAssertFalse(reason.contains(root.path))
        }

        try? FileManager.default.removeItem(at: credential)
        let target = root.appendingPathComponent("target")
        try Data("symlink-secret\n".utf8).write(to: target)
        XCTAssertEqual(target.path.withCString { Glibc.chmod($0, 0o600) }, 0)
        XCTAssertEqual(
            target.path.withCString { targetPath in
                credential.path.withCString { linkPath in
                    Glibc.symlink(targetPath, linkPath)
                }
            },
            0
        )
        XCTAssertThrowsError(
            try store.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        ) { error in
            guard case .backendUnavailable = error as? LinuxSecretStoreError else {
                return XCTFail("Expected backendUnavailable for symlink, got \(error)")
            }
        }
    }
#endif

    func testSecretStoreSetupProbeIncludesLibsecretTPMAndUXBlockers() {
        let rows = LinuxSecretStoreSetupProbeBuilder.rows(
            secretToolPath: nil,
            hasSessionBus: false,
            tpm2ToolPath: nil,
            hasTPMDevice: false
        )

        XCTAssertTrue(rows.contains { $0.backend == "org.freedesktop.secrets" && $0.status == "blocked" })
        XCTAssertTrue(rows.contains { $0.backend == "kwallet" && $0.status == "test_command_fixture" })
        XCTAssertTrue(rows.contains { $0.backend == "systemd_credentials" && $0.status == "fallback_supported" })
        XCTAssertTrue(rows.contains { $0.backend == "tpm2" && $0.status == "blocked_optional_hardening" })
        XCTAssertTrue(rows.allSatisfy { $0.setupUX.isEmpty == false })
    }

    func testDesktopOwnerLocalAuthenticationUsesPolkitAllowUserInteraction() async throws {
        let polkit = FakePolkitAuthority(
            result: .success(LinuxPolkitAuthorizationResult(isAuthorized: true, isChallenge: false))
        )
        let authenticator = LinuxDesktopOwnerAuthenticator(
            polkit: polkit,
            pam: FakePAMAuthenticator(result: .failure(.pamUnavailable("not reached"))),
            processID: 42,
            nowMillis: { 1_800_000_000_123 }
        )

        let proof = try await authenticator.authenticate(
            reason: "Allow Desktop Computer Use tools for this agent thread."
        )

        XCTAssertTrue(proof.localAuthenticationSatisfied)
        XCTAssertEqual(proof.authority, "polkit")
        XCTAssertEqual(proof.actionID, LinuxDesktopOwnerAuthenticator.computerUseGrantActionID)
        XCTAssertEqual(proof.authenticatedAtMillis, 1_800_000_000_123)
        XCTAssertEqual(polkit.calls.count, 1)
        XCTAssertEqual(polkit.calls[0].actionID, LinuxDesktopOwnerAuthenticator.computerUseGrantActionID)
        XCTAssertEqual(polkit.calls[0].unixProcessID, 42)
        XCTAssertTrue(polkit.calls[0].allowUserInteraction)
    }

    func testDesktopOwnerLocalAuthenticationFallsBackToPAMWhenPolkitUnavailable() async throws {
        let polkit = FakePolkitAuthority(
            result: .failure(.polkitUnavailable("system bus unavailable"))
        )
        let pam = FakePAMAuthenticator(result: .success(true))
        let authenticator = LinuxDesktopOwnerAuthenticator(
            polkit: polkit,
            pam: pam,
            processID: 43,
            nowMillis: { 1_800_000_000_456 }
        )

        let proof = try await authenticator.authenticate(reason: "Allow trusted Computer Use session.")

        XCTAssertTrue(proof.localAuthenticationSatisfied)
        XCTAssertEqual(proof.authority, "pam")
        XCTAssertEqual(polkit.calls.count, 1)
        XCTAssertEqual(pam.calls.count, 1)
        XCTAssertEqual(pam.calls[0].serviceName, LinuxDesktopOwnerAuthenticator.defaultPAMServiceName)
    }

    func testDesktopOwnerLocalAuthenticationFailsClosedForDeniedAndUnavailablePaths() async throws {
        let deniedPolkit = LinuxDesktopOwnerAuthenticator(
            polkit: FakePolkitAuthority(
                result: .success(LinuxPolkitAuthorizationResult(isAuthorized: false, isChallenge: true))
            ),
            pam: FakePAMAuthenticator(result: .success(true))
        )
        do {
            _ = try await deniedPolkit.authenticate(reason: "Allow Desktop Computer Use tools.")
            XCTFail("polkit denial must fail closed")
        } catch {
            XCTAssertEqual(error as? LinuxDesktopOwnerAuthenticationError, .polkitDenied)
        }

        let unavailable = LinuxDesktopOwnerAuthenticator(
            polkit: FakePolkitAuthority(result: .failure(.polkitUnavailable("system bus unavailable"))),
            pam: FakePAMAuthenticator(result: .failure(.pamUnavailable("no conversation provider")))
        )
        do {
            _ = try await unavailable.authenticate(reason: "Allow Desktop Computer Use tools.")
            XCTFail("unavailable polkit + PAM must fail closed")
        } catch {
            XCTAssertEqual(
                error as? LinuxDesktopOwnerAuthenticationError,
                .localAuthUnavailable("no conversation provider")
            )
        }
    }

    func testPKCELoopbackAuthAndTokenCustody() async throws {
        let flow = LinuxPKCELoopbackFlow(
            authBaseURL: URL(string: "https://securetoken.google.com/auth")!,
            clientID: "linux-client",
            callbackPort: 41277,
            state: "state-123",
            verifier: "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ._-~",
            scopes: ["openid", "email"]
        )
        let authURL = try XCTUnwrap(URLComponents(url: flow.authURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(authURL.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(authURL.queryItems?.first(where: { $0.name == "redirect_uri" })?.value, "http://127.0.0.1:41277/callback")
        XCTAssertFalse(flow.authURL.absoluteString.contains("webview"))

        let code = try flow.acceptCallback(URL(string: "http://127.0.0.1:41277/callback?state=state-123&code=firebase-code")!)
        XCTAssertEqual(code, "firebase-code")
        XCTAssertThrowsError(
            try flow.acceptCallback(URL(string: "http://127.0.0.1:41277/callback?state=bad&code=firebase-code")!)
        ) { error in
            XCTAssertEqual(error as? LinuxAuthError, .stateMismatch)
        }

        let authHarness = LinuxSecretCommandHarness(kind: .secretService)
        let authBackend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { executableURL, arguments, standardInput in
                try authHarness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        let custodian = LinuxSecretCustodian(backends: [authBackend])
        let tokenStore = LinuxAuthTokenStore(custodian: custodian)
        _ = try tokenStore.storeRefreshToken("refresh-secret")
        XCTAssertEqual(try tokenStore.restoreRefreshToken().trustLevel, .secretService)

        let signOut = LinuxAuthSessionController(tokenStore: tokenStore) { metadata in
            XCTAssertEqual(metadata.backend, "org.freedesktop.secrets")
            XCTAssertEqual(metadata.secretClass, .refreshToken)
        }
        let signOutResult = try await signOut.signOut()
        XCTAssertTrue(signOutResult.remoteRevocationAttempted)
        XCTAssertTrue(signOutResult.localSessionCleared)
        XCTAssertThrowsError(try tokenStore.restoreRefreshToken())
    }

    func testSecretStoreCommandFailureDoesNotExposeRetrievedSecretOutput() throws {
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { _, _, _ in
                LinuxSecretCommandResult(
                    exitCode: 2,
                    stdout: "retrieved-secret-must-not-escape",
                    stderr: "keyring is locked\nretry after unlock"
                )
            }
        )

        XCTAssertThrowsError(
            try backend.readSecret(id: "firebase-refresh-token", secretClass: .refreshToken)
        ) { error in
            let description = String(describing: error)
            XCTAssertFalse(description.contains("retrieved-secret-must-not-escape"))
            XCTAssertTrue(description.contains("keyring is locked retry after unlock"))
        }
    }

    func testLockedNativeKeyringFailsClosedWithoutEnvironmentFallback() throws {
        let native = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { _, _, _ in
                LinuxSecretCommandResult(exitCode: 1, stderr: "keyring is locked")
            }
        )
        let fallback = LinuxHeadlessSecretStoreBackend(
            environment: ["OPENBURNBAR_FIREBASE_REFRESH_TOKEN": "plaintext-process-secret"],
            allowsEnvironmentSecrets: true
        )
        let custodian = LinuxSecretCustodian(backends: [native, fallback])

        XCTAssertThrowsError(
            try custodian.requireHighValueSecret(
                id: "firebase-refresh-token",
                secretClass: .refreshToken
            )
        ) { error in
            guard case let LinuxSecretStoreError.commandFailed(backend, operation, detail) = error else {
                return XCTFail("Expected native keyring failure, got \(error)")
            }
            XCTAssertEqual(backend, "org.freedesktop.secrets")
            XCTAssertEqual(operation, "read")
            XCTAssertEqual(detail, "keyring is locked")
        }
    }

    func testDeletingSecretSkipsWritableBackendsWithoutTheItem() throws {
        let emptyHarness = LinuxSecretCommandHarness(kind: .secretService)
        let populatedHarness = LinuxSecretCommandHarness(kind: .kwallet)
        let empty = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { executableURL, arguments, standardInput in
                try emptyHarness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        let populated = LinuxNativeSecretStoreBackend(
            kind: .kwallet,
            executableURL: URL(fileURLWithPath: "/usr/bin/kwallet-query"),
            runner: { executableURL, arguments, standardInput in
                try populatedHarness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        _ = try populated.storeSecret(
            "stored-in-kwallet",
            id: "firebase-refresh-token",
            secretClass: .refreshToken
        )
        let custodian = LinuxSecretCustodian(backends: [empty, populated])

        try custodian.deleteHighValueSecret(
            id: "firebase-refresh-token",
            secretClass: .refreshToken
        )

        XCTAssertFalse(emptyHarness.arguments.contains { $0.first == "clear" })
        XCTAssertTrue(populatedHarness.arguments.contains { $0.contains("-d") })
        XCTAssertNil(
            try populated.readSecret(id: "firebase-refresh-token", secretClass: .refreshToken)
        )
    }

    func testSignOutClearsLocalTokenWhenRemoteRevocationFails() async throws {
        struct RevocationFailure: Error {}

        let harness = LinuxSecretCommandHarness(kind: .secretService)
        let backend = LinuxNativeSecretStoreBackend(
            kind: .secretService,
            executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"),
            runner: { executableURL, arguments, standardInput in
                try harness.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput
                )
            }
        )
        let tokenStore = LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend]))
        _ = try tokenStore.storeRefreshToken("refresh-secret")
        let controller = LinuxAuthSessionController(tokenStore: tokenStore) { _ in
            throw RevocationFailure()
        }

        do {
            _ = try await controller.signOut()
            XCTFail("Expected remote revocation to fail")
        } catch is RevocationFailure {
            // Expected: local token custody must still be cleared.
        }
        XCTAssertThrowsError(try tokenStore.restoreRefreshToken())
    }

    func testFirebaseAuthProtocolFixturesAndBrowserLaunchAreRedacted() async throws {
        let flow = LinuxPKCELoopbackFlow(
            authBaseURL: URL(string: "https://securetoken.google.com/auth")!,
            clientID: "linux-client",
            callbackPort: 41277,
            state: "state-123",
            verifier: "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ._-~",
            scopes: ["openid", "email"]
        )
        let launch = LinuxAuthProtocolEvidence.browserLaunch(flow: flow)
        XCTAssertEqual(launch["launcher"], "xdg-open")
        XCTAssertEqual(launch["custody"], "external_browser_no_embedded_webview")

        let signIn = LinuxAuthProtocolEvidence.signInWithIdpExchange(apiKey: "test-api-key", providerID: "google.com")
        XCTAssertEqual(signIn.method, "POST")
        XCTAssertTrue(signIn.url.contains("accounts:signInWithIdp"))
        XCTAssertEqual(signIn.requestBody["returnSecureToken"], "true")
        XCTAssertFalse(signIn.requestBody.values.joined().contains("id-token-value"))
        XCTAssertEqual(signIn.responseBody["refreshTokenCustody"], "SecretStore metadata only")

        let metadata = LinuxSecretMetadata(
            id: "firebase-refresh-token",
            secretClass: .refreshToken,
            trustLevel: .secretService,
            backend: "org.freedesktop.secrets.test",
            createdAtMillis: 1_800_000_000_000,
            note: "metadata only"
        )
        let revoke = LinuxAuthProtocolEvidence.revokeRefreshTokenExchange(apiKey: "test-api-key", metadata: metadata)
        XCTAssertTrue(revoke.url.contains("accounts:update"))
        XCTAssertEqual(revoke.requestBody["tokenBackend"], "org.freedesktop.secrets.test")
        XCTAssertEqual(revoke.responseBody["localSessionCleared"], "true")
    }

    func testStripeMembershipRestoreFixtureHasNoStoreKitDependency() async throws {
        let client = LinuxMembershipClient { uid in
            XCTAssertEqual(uid, "user-1")
            return LinuxMembershipRestoreResult(
                state: .active,
                entitlementID: "burnbar_pro",
                source: "stripe_checkout"
            )
        }
        let result = try await client.restoreEntitlement(uid: "user-1")
        XCTAssertEqual(result.state, .active)
        XCTAssertEqual(result.entitlementID, "burnbar_pro")
        XCTAssertEqual(result.source, "stripe_checkout")

        let cancelled = LinuxMembershipRestoreResult(state: .cancelled, entitlementID: nil, source: "stripe_portal")
        let failed = LinuxMembershipRestoreResult(state: .paymentFailed, entitlementID: nil, source: "stripe_invoice")
        let offline = LinuxMembershipRestoreResult(state: .offline, entitlementID: nil, source: "local_cache")
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(failed.state, .paymentFailed)
        XCTAssertEqual(offline.state, .offline)
    }

    func testMembershipProtocolAndDaemonShellCacheUpdate() {
        let checkout = LinuxMembershipProtocolEvidence.checkoutSession(uid: "user-1")
        XCTAssertEqual(checkout.requestHeaders["stripe-mode"], "test")
        XCTAssertTrue(checkout.url.contains("/checkout/sessions"))
        XCTAssertEqual(checkout.responseBody["id"], "cs_test_openburnbar")

        let portal = LinuxMembershipProtocolEvidence.portalSession(uid: "user-1")
        XCTAssertTrue(portal.url.contains("/billing_portal/sessions"))

        var cache = LinuxMembershipEntitlementCache()
        let update = cache.apply(
            uid: "user-1",
            result: LinuxMembershipRestoreResult(state: .active, entitlementID: "burnbar_pro", source: "stripe_checkout")
        )
        XCTAssertEqual(update.daemonCacheKey, "entitlements/user-1")
        XCTAssertEqual(update.shellCacheEvent, "membership.entitlement_cache.updated")
        XCTAssertEqual(cache.entries["user-1"]?.entitlementID, "burnbar_pro")
    }

    func testTelemetryConsentRedactionAndSupportBundleSample() {
        let redactor = LinuxTelemetryRedactor()
        let seeded = "token=sk-ant-abcdefghijklmnopqrstuvwxyz refreshToken=secret123 email=alberto@example.com path=/home/alberto/.config/openburnbar/session.json cookie=sessionid apiKey=key123 prompt=private words"
        let redacted = redactor.redact(seeded)
        XCTAssertFalse(redacted.contains("sk-ant"))
        XCTAssertFalse(redacted.contains("secret123"))
        XCTAssertFalse(redacted.contains("alberto@example.com"))
        XCTAssertFalse(redacted.contains("/home/alberto"))
        XCTAssertFalse(redacted.contains("sessionid"))
        XCTAssertFalse(redacted.contains("key123"))
        XCTAssertFalse(redacted.contains("private words"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))

        let captured = TelemetryCaptureBox()
        let recorderOff = LinuxTelemetryRecorder(consent: .declined) { event, properties in
            captured.append((event, properties))
        }
        recorderOff.record(event: "linux.auth.error", properties: ["detail": seeded])
        XCTAssertTrue(captured.events.isEmpty)

        let recorderOn = LinuxTelemetryRecorder(consent: .granted) { event, properties in
            captured.append((event, properties))
        }
        recorderOn.record(event: "linux.auth.error", properties: ["detail": seeded, "trust_class": "linux_lower_trust"])
        XCTAssertEqual(captured.events.count, 1)
        XCTAssertEqual(captured.events[0].0, "linux.auth.error")
        XCTAssertEqual(captured.events[0].1["trust_class"], "linux_lower_trust")
        XCTAssertFalse(captured.events[0].1["detail"]?.contains("alberto@example.com") ?? true)

        let bundle = LinuxSupportBundle().render(entries: [seeded, "trust_class=linux_lower_trust"])
        XCTAssertTrue(bundle.contains("trust_class=linux_lower_trust"))
        XCTAssertFalse(bundle.contains("sk-ant"))
        XCTAssertFalse(bundle.contains("/home/alberto"))
    }

    func testTelemetryRedactorCoversJSONBearerAndLinuxPathForms() {
        let redactor = LinuxTelemetryRedactor()
        let diagnostic = #"{"apiKey":"json-secret","access_token":"json-refresh","authorization":"Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature","session_id":"session-secret","path":"/run/user/1000/openburnbar/session.json"}"#

        let redacted = redactor.redact(diagnostic)

        XCTAssertTrue(redacted.contains(#""apiKey":[REDACTED]"#))
        XCTAssertTrue(redacted.contains(#""access_token":[REDACTED]"#))
        XCTAssertTrue(redacted.contains(#""authorization":[REDACTED]"#))
        XCTAssertTrue(redacted.contains(#""session_id":[REDACTED]"#))
        XCTAssertFalse(redacted.contains("json-secret"))
        XCTAssertFalse(redacted.contains("json-refresh"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(redacted.contains("/run/user/1000"))
    }

    func testTelemetryBridgeControlsAndRedactionSurfaceProofs() {
        let seeded = "token=sk-ant-abcdefghijklmnopqrstuvwxyz refreshToken=secret123 email=alberto@example.com path=/home/alberto/.config/openburnbar/session.json cookie=sessionid apiKey=key123 prompt=private operator request"
        var controls = LinuxTelemetryControlStore()
        controls.record(event: "linux.auth.error", consent: .declined, properties: ["detail": seeded])
        XCTAssertTrue(controls.captured.isEmpty)

        controls.record(event: "linux.auth.error", consent: .granted, properties: ["detail": seeded])
        XCTAssertEqual(controls.captured.count, 1)
        let exported = controls.export()
        XCTAssertEqual(exported.count, 1)
        XCTAssertFalse(exported[0]["detail"]?.contains("alberto@example.com") ?? true)
        controls.disable()
        controls.record(event: "linux.auth.error", consent: .granted, properties: ["detail": seeded])
        XCTAssertEqual(controls.captured.count, 1)
        controls.deleteAll()
        XCTAssertTrue(controls.export().isEmpty)

        let proofs = LinuxRedactionSurfaceEvidence.proofs(seed: seeded)
        XCTAssertEqual(
            Set(proofs.map(\.surface)),
            Set(["daemon_journal", "provider_payload_trace", "crash_error_report", "release_evidence_log"])
        )
        XCTAssertTrue(proofs.allSatisfy { $0.rawMarkerFound == false })
    }

    func testCloudSyncPrivacyBOLASealedPayloadsAndWatermarkCommitBoundary() throws {
        let guardrail = LinuxCloudSyncPrivacyGuard(uid: "user-1")
        XCTAssertNoThrow(try guardrail.validateUpload(LinuxCloudSyncDocument(
            path: "users/user-1/chat_threads/thread-1",
            fields: [
                "titleSealed": "base64-envelope",
                "bodySealed": "base64-envelope",
                "updatedAt": "1800000000000"
            ]
        )))

        XCTAssertThrowsError(try guardrail.validateUpload(LinuxCloudSyncDocument(
            path: "users/user-2/chat_threads/thread-1",
            fields: ["bodySealed": "base64-envelope"]
        ))) { error in
            guard case .bolaDenied = error as? LinuxCloudSyncPrivacyError else {
                return XCTFail("expected BOLA denial, got \(error)")
            }
        }

        XCTAssertThrowsError(try guardrail.validateUpload(LinuxCloudSyncDocument(
            path: "users/user-1/chat_threads/thread-1",
            fields: ["body": "plaintext transcript"]
        ))) { error in
            XCTAssertEqual(error as? LinuxCloudSyncPrivacyError, .plaintextPrivateField(field: "body"))
        }

        var tx = LinuxCloudSyncTransaction()
        tx.recordProcessed(remoteUpdateMillis: 1_800_000_000_000)
        XCTAssertThrowsError(try tx.watermarkAfterCommit()) { error in
            XCTAssertEqual(error as? LinuxCloudSyncPrivacyError, .watermarkBeforeCommit)
        }
        tx.recordProcessed(remoteUpdateMillis: 1_800_000_010_000)
        tx.commit()
        XCTAssertEqual(try tx.watermarkAfterCommit(), 1_800_000_010_000)
    }

    func testCloudSyncLocalStagingTransportRetryConflictAndWatermarkEvidence() throws {
        var simulator = LinuxCloudSyncLocalStagingSimulator(uid: "user-1")
        let rows = try simulator.run()
        XCTAssertTrue(rows.contains { $0.transport == .callable && $0.step == "callable_owner_upload_allowed" })
        XCTAssertTrue(rows.contains { $0.transport == .firestoreREST && $0.step == "rest_patch_transform_update" })
        XCTAssertTrue(rows.contains { $0.transport == .firestoreListenWebSocket && $0.step == "listen_ws_remote_update" })
        XCTAssertTrue(rows.contains { $0.step == "rules_owner_mismatch_denied" && $0.response.contains("403") })
        XCTAssertTrue(rows.contains { $0.step == "retry_backoff_before_commit" && $0.backoffMillis == [100, 250, 500] })
        XCTAssertTrue(rows.contains { $0.step == "conflict_remote_newer_wins" && $0.conflictResolution == "remote_newer_by_update_time" })
        XCTAssertEqual(rows.last?.watermark, 1_800_000_001_000)
    }
}

private final class FakePolkitAuthority: LinuxPolkitAuthorizing, @unchecked Sendable {
    typealias Call = (actionID: String, unixProcessID: Int32, allowUserInteraction: Bool)

    private let queue = DispatchQueue(label: "FakePolkitAuthority")
    private let result: Result<LinuxPolkitAuthorizationResult, LinuxDesktopOwnerAuthenticationError>
    private var recordedCalls: [Call] = []
    var calls: [Call] { queue.sync { recordedCalls } }

    init(result: Result<LinuxPolkitAuthorizationResult, LinuxDesktopOwnerAuthenticationError>) {
        self.result = result
    }

    func checkAuthorization(
        actionID: String,
        unixProcessID: Int32,
        allowUserInteraction: Bool
    ) async throws -> LinuxPolkitAuthorizationResult {
        queue.sync {
            recordedCalls.append((actionID, unixProcessID, allowUserInteraction))
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class FakePAMAuthenticator: LinuxPAMAuthenticating, @unchecked Sendable {
    typealias Call = (serviceName: String, reason: String)

    private let queue = DispatchQueue(label: "FakePAMAuthenticator")
    private let result: Result<Bool, LinuxDesktopOwnerAuthenticationError>
    private var recordedCalls: [Call] = []
    var calls: [Call] { queue.sync { recordedCalls } }

    init(result: Result<Bool, LinuxDesktopOwnerAuthenticationError>) {
        self.result = result
    }

    func authenticate(serviceName: String, reason: String) async throws -> Bool {
        queue.sync {
            recordedCalls.append((serviceName, reason))
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class LinuxSecretCommandHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let kind: LinuxNativeSecretStoreKind
    private var storedSecret: String?
    private var recordedArguments: [[String]] = []
    private var recordedStandardInput: String?

    init(kind: LinuxNativeSecretStoreKind) {
        self.kind = kind
    }

    var arguments: [[String]] {
        lock.withLock { recordedArguments }
    }

    var lastStandardInput: String? {
        lock.withLock { recordedStandardInput }
    }

    func run(
        executableURL _: URL,
        arguments: [String],
        standardInput: Data?
    ) throws -> LinuxSecretCommandResult {
        lock.withLock {
            recordedArguments.append(arguments)
            if let standardInput {
                recordedStandardInput = String(decoding: standardInput, as: UTF8.self)
            }

            let operation: String
            switch kind {
            case .secretService:
                operation = arguments.first ?? ""
            case .kwallet:
                operation = arguments.contains("-w") ? "store"
                    : arguments.contains("-r") ? "lookup"
                    : arguments.contains("-d") ? "clear"
                    : "health"
            }
            switch operation {
            case "store":
                if let standardInput {
                    var value = String(decoding: standardInput, as: UTF8.self)
                    if value.hasSuffix("\n") {
                        value.removeLast()
                        if value.hasSuffix("\r") {
                            value.removeLast()
                        }
                    }
                    storedSecret = value
                } else {
                    storedSecret = nil
                }
                return LinuxSecretCommandResult(exitCode: 0)
            case "lookup":
                if let storedSecret {
                    return LinuxSecretCommandResult(exitCode: 0, stdout: storedSecret + "\n")
                }
                return LinuxSecretCommandResult(exitCode: 1, stderr: "not found")
            case "clear":
                storedSecret = nil
                return LinuxSecretCommandResult(exitCode: 0)
            default:
                return LinuxSecretCommandResult(exitCode: 0)
            }
        }
    }
}

private final class TelemetryCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, [String: String])] = []

    func append(_ event: (String, [String: String])) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [(String, [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StringArrayCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
