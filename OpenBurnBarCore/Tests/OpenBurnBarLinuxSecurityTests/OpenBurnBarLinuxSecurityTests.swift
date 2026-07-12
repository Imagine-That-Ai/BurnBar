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
        let custodian = LinuxSecretCustodian(backends: [backend])

        _ = try custodian.storeHighValueSecret(
            secret,
            id: "whitespace",
            secretClass: .providerCredential
        )

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
        XCTAssertTrue(auditKey.metadata.note.contains("systemd credential"))
    }

    func testHeadlessCredentialIDsAndPathsAreConfinedBeforeReading() throws {
        let readerCalled = ThreadSafeBoolean()
        let invalidIDStore = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { _ in
                readerCalled.setTrue()
                return "unexpected"
            }
        )

        XCTAssertThrowsError(
            try invalidIDStore.readSecret(id: "../audit-key", secretClass: .auditSigningKey)
        ) { error in
            XCTAssertEqual(error as? LinuxSecretStoreError, .invalidSecretID("../audit-key"))
        }
        XCTAssertFalse(readerCalled.value)

        let relativeDirectoryStore = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "relative/credentials"],
            credentialReader: { _ in
                readerCalled.setTrue()
                return "unexpected"
            }
        )
        XCTAssertThrowsError(
            try relativeDirectoryStore.readSecret(id: "audit-key", secretClass: .auditSigningKey)
        ) { error in
            guard case .backendUnavailable = error as? LinuxSecretStoreError else {
                return XCTFail("Expected invalid credential directory, got \(error)")
            }
        }
        XCTAssertFalse(readerCalled.value)

        let pathProbe = ThreadSafeString()
        let namespacedIDStore = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { path in
                pathProbe.set(path)
                return "namespaced-secret"
            }
        )
        XCTAssertEqual(
            try namespacedIDStore.readSecret(
                id: "com.openburnbar.provider:provider.zai.apiKey",
                secretClass: .providerCredential
            )?.secret,
            "namespaced-secret"
        )
        XCTAssertEqual(
            pathProbe.value,
            "/run/credentials/openburnbar.service/com.openburnbar.provider_3Aprovider.zai.apiKey"
        )

        _ = try namespacedIDStore.readSecret(
            id: "com.openburnbar.provider_3Aprovider.zai.apiKey",
            secretClass: .providerCredential
        )
        XCTAssertEqual(
            pathProbe.value,
            "/run/credentials/openburnbar.service/com.openburnbar.provider_5F3Aprovider.zai.apiKey"
        )
    }

#if os(Linux)
    func testSystemdCredentialReaderValidatesDescriptorsMetadataAndBounds() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-systemd-credential-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: directory) }

        let credential = directory.appendingPathComponent("audit-signing-key")
        try Data("  audit-secret  \n".utf8).write(to: credential)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let backend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": directory.path]
        )

        let record = try XCTUnwrap(
            backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        XCTAssertEqual(record.secret, "  audit-secret  ")
        XCTAssertEqual(record.metadata.trustLevel, .systemdCredential)

        // Group read/execute bits mirror the POSIX ACL mask that systemd 254+
        // sets for DynamicUser=true services, but only root-owned entries may
        // carry them; user-owned entries stay strictly private.
        try fileManager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: directory.path)
        if geteuid() == 0 {
            XCTAssertNoThrow(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        } else {
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        }

        // World access and group-write are rejected for every owner.
        try fileManager.setAttributes([.posixPermissions: 0o705], ofItemAtPath: directory.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        try fileManager.setAttributes([.posixPermissions: 0o770], ofItemAtPath: directory.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: credential.path)
        if geteuid() == 0 {
            XCTAssertNoThrow(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        } else {
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: credential.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        try fileManager.setAttributes([.posixPermissions: 0o660], ofItemAtPath: credential.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)

        try fileManager.removeItem(at: credential)
        let symlinkTarget = directory.appendingPathComponent("symlink-target")
        try Data("target-secret".utf8).write(to: symlinkTarget)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: symlinkTarget.path)
        try fileManager.createSymbolicLink(at: credential, withDestinationURL: symlinkTarget)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )

        try fileManager.removeItem(at: credential)
        try Data(repeating: 0x61, count: 16_385).write(to: credential)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
    }

    func testSystemdCredentialReaderTreatsAbsentCredentialsAsMissing() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-systemd-absent-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: directory) }

        // A valid credentials directory that does not provide this credential
        // reports no record instead of a backend failure.
        let backend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": directory.path]
        )
        XCTAssertNil(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )

        // An absent credentials directory means no systemd credentials at all.
        let absentDirectoryBackend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": directory.appendingPathComponent("absent").path]
        )
        XCTAssertNil(
            try absentDirectoryBackend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
    }

    func testSystemdCredentialReaderRejectsSymlinkedDirectoryWrongOwnersAndNonRegularFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-systemd-types-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("credentials", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: root) }

        let credential = directory.appendingPathComponent("audit-signing-key")
        try Data("audit-secret".utf8).write(to: credential)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let backend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": directory.path]
        )

        let linkedDirectory = root.appendingPathComponent("credentials-link")
        try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        let linkedBackend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": linkedDirectory.path]
        )
        XCTAssertThrowsError(
            try linkedBackend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )

        if geteuid() == 0 {
            XCTAssertEqual(Glibc.chown(directory.path, 65_534, 65_534), 0)
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
            XCTAssertEqual(Glibc.chown(directory.path, 0, 0), 0)

            XCTAssertEqual(Glibc.chown(credential.path, 65_534, 65_534), 0)
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
            XCTAssertEqual(Glibc.chown(credential.path, 0, 0), 0)
        }

        try fileManager.removeItem(at: credential)
        XCTAssertEqual(Glibc.mkfifo(credential.path, 0o600), 0)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )

        try fileManager.removeItem(at: credential)
        try fileManager.createDirectory(at: credential, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credential.path)
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
    }

    func testSystemdCredentialReaderRejectsMalformedContentAndAcceptsExactLimit() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-systemd-content-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: directory) }

        let credential = directory.appendingPathComponent("audit-signing-key")
        let backend = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": directory.path]
        )

        func replaceCredential(with data: Data) throws {
            try? fileManager.removeItem(at: credential)
            try data.write(to: credential)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        }

        for malformed in [
            Data([0xFF]),
            Data("secret\0value".utf8),
            Data("secret\rvalue".utf8),
            Data("secret\nvalue".utf8)
        ] {
            try replaceCredential(with: malformed)
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        }

        for missing in [Data(), Data(" \t ".utf8)] {
            try replaceCredential(with: missing)
            XCTAssertThrowsError(
                try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
            )
        }

        let exactLimit = Data(repeating: 0x61, count: 16_384)
        try replaceCredential(with: exactLimit)
        let record = try XCTUnwrap(
            backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
        XCTAssertEqual(record.secret.utf8.count, 16_384)

        try replaceCredential(with: Data(repeating: 0x61, count: 16_385))
        XCTAssertThrowsError(
            try backend.readSecret(id: "audit-signing-key", secretClass: .auditSigningKey)
        )
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

    func testMutationBackendArbitrationFailsClosedAfterPrimaryErrors() throws {
        let lockedPrimary = LinuxSecretMutationProbeBackend(
            backendName: "locked-primary",
            healthFailure: .backendUnavailable("primary is locked")
        )
        let writableFallback = LinuxSecretMutationProbeBackend(backendName: "fallback")
        let storeCustodian = LinuxSecretCustodian(backends: [lockedPrimary, writableFallback])

        XCTAssertThrowsError(
            try storeCustodian.storeHighValueSecret(
                "secret",
                id: "provider-token",
                secretClass: .providerCredential
            )
        ) { error in
            XCTAssertEqual(error as? LinuxSecretStoreError, .backendUnavailable("primary is locked"))
        }
        XCTAssertEqual(lockedPrimary.healthCheckCount, 1)
        XCTAssertEqual(writableFallback.healthCheckCount, 0)
        XCTAssertEqual(writableFallback.storeCount, 0)

        let populatedPrimary = LinuxSecretMutationProbeBackend(
            backendName: "populated-primary",
            initialSecret: "stale-secret"
        )
        let unreadableSecondary = LinuxSecretMutationProbeBackend(
            backendName: "unreadable-secondary",
            readFailure: .commandFailed(
                backend: "unreadable-secondary",
                operation: "read",
                detail: "secondary is locked"
            )
        )
        let deleteCustodian = LinuxSecretCustodian(backends: [populatedPrimary, unreadableSecondary])

        XCTAssertThrowsError(
            try deleteCustodian.deleteHighValueSecret(
                id: "provider-token",
                secretClass: .providerCredential
            )
        ) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                .commandFailed(
                    backend: "unreadable-secondary",
                    operation: "read",
                    detail: "secondary is locked"
                )
            )
        }
        XCTAssertEqual(populatedPrimary.readCount, 1)
        XCTAssertEqual(unreadableSecondary.readCount, 1)
        XCTAssertEqual(populatedPrimary.deleteCount, 0)
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

    func testDeletingSecretRemovesEveryMutableCopy() throws {
        let first = LinuxSecretMutationProbeBackend(
            backendName: "secret-service",
            initialSecret: "first-copy"
        )
        let second = LinuxSecretMutationProbeBackend(
            backendName: "kwallet",
            initialSecret: "second-copy"
        )
        let custodian = LinuxSecretCustodian(backends: [first, second])

        try custodian.deleteHighValueSecret(
            id: "provider-token",
            secretClass: .providerCredential
        )

        XCTAssertEqual(first.readCount, 1)
        XCTAssertEqual(second.readCount, 1)
        XCTAssertEqual(first.deleteCount, 1)
        XCTAssertEqual(second.deleteCount, 1)
        XCTAssertNil(try first.readSecret(id: "provider-token", secretClass: .providerCredential))
        XCTAssertNil(try second.readSecret(id: "provider-token", secretClass: .providerCredential))
    }

    func testDeletingSecretReportsMatchingReadOnlySystemdCredential() throws {
        let writable = LinuxSecretMutationProbeBackend(backendName: "secret-service")
        let systemd = LinuxInMemorySecretStoreBackend(
            backendName: "systemd-credential",
            trustLevel: .systemdCredential,
            secrets: ["provider-token": "systemd-copy"]
        )
        let custodian = LinuxSecretCustodian(backends: [writable, systemd])

        XCTAssertThrowsError(
            try custodian.deleteHighValueSecret(
                id: "provider-token",
                secretClass: .providerCredential
            )
        ) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                LinuxSecretStoreError.readOnlySecretRemains(
                    id: "provider-token",
                    backends: ["systemd-credential"]
                )
            )
        }
        XCTAssertEqual(writable.readCount, 1)
        XCTAssertEqual(writable.deleteCount, 0)

        let record = try custodian.requireHighValueSecret(
            id: "provider-token",
            secretClass: .providerCredential
        )
        XCTAssertEqual(record.secret, "systemd-copy")
        XCTAssertEqual(record.metadata.trustLevel, .systemdCredential)
    }

    func testAbsentSystemdCredentialFallsThroughOnRead() throws {
        let headless = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { _ in nil }
        )
        XCTAssertNil(
            try headless.readSecret(id: "provider-token", secretClass: .providerCredential)
        )

        let fallback = LinuxInMemorySecretStoreBackend(secrets: ["provider-token": "wallet-copy"])
        let record = try LinuxSecretCustodian(backends: [headless, fallback])
            .requireHighValueSecret(id: "provider-token", secretClass: .providerCredential)
        XCTAssertEqual(record.secret, "wallet-copy")

        XCTAssertThrowsError(
            try LinuxSecretCustodian(backends: [headless]).requireHighValueSecret(
                id: "provider-token",
                secretClass: .providerCredential
            )
        ) { error in
            XCTAssertEqual(error as? LinuxSecretStoreError, .missingSecret("provider-token"))
        }
    }

    func testDeletingSecretTreatsAbsentSystemdCredentialAsMissing() throws {
        let writable = LinuxSecretMutationProbeBackend(
            backendName: "secret-service",
            initialSecret: "mutable-copy"
        )
        let headless = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { _ in nil }
        )
        let custodian = LinuxSecretCustodian(backends: [writable, headless])

        try custodian.deleteHighValueSecret(id: "provider-token", secretClass: .providerCredential)

        XCTAssertEqual(writable.deleteCount, 1)
        XCTAssertNil(try writable.readSecret(id: "provider-token", secretClass: .providerCredential))
    }

    func testDeletingSecretStillFailsClosedWhenSystemdCredentialProbeErrors() throws {
        let writable = LinuxSecretMutationProbeBackend(
            backendName: "secret-service",
            initialSecret: "mutable-copy"
        )
        let headless = LinuxHeadlessSecretStoreBackend(
            environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar.service"],
            credentialReader: { _ in
                throw LinuxSecretStoreError.backendUnavailable(
                    "systemd credential failed type, ownership, mode, or size validation"
                )
            }
        )
        let custodian = LinuxSecretCustodian(backends: [writable, headless])

        XCTAssertThrowsError(
            try custodian.deleteHighValueSecret(id: "provider-token", secretClass: .providerCredential)
        ) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                .backendUnavailable(
                    "systemd credential failed type, ownership, mode, or size validation"
                )
            )
        }
        XCTAssertEqual(writable.deleteCount, 0)
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

private final class ThreadSafeBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func setTrue() {
        lock.withLock { storage = true }
    }
}

private final class ThreadSafeString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? { lock.withLock { storage } }

    func set(_ value: String) {
        lock.withLock { storage = value }
    }
}

private final class LinuxSecretMutationProbeBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName: String
    let trustLevel: LinuxSecretTrustLevel = .secretService
    let supportsMutations = true

    private let lock = NSLock()
    private let healthFailure: LinuxSecretStoreError?
    private let readFailure: LinuxSecretStoreError?
    private var secret: String?
    private var recordedHealthCheckCount = 0
    private var recordedReadCount = 0
    private var recordedStoreCount = 0
    private var recordedDeleteCount = 0

    init(
        backendName: String,
        initialSecret: String? = nil,
        healthFailure: LinuxSecretStoreError? = nil,
        readFailure: LinuxSecretStoreError? = nil
    ) {
        self.backendName = backendName
        secret = initialSecret
        self.healthFailure = healthFailure
        self.readFailure = readFailure
    }

    var healthCheckCount: Int { lock.withLock { recordedHealthCheckCount } }
    var readCount: Int { lock.withLock { recordedReadCount } }
    var storeCount: Int { lock.withLock { recordedStoreCount } }
    var deleteCount: Int { lock.withLock { recordedDeleteCount } }

    func healthCheck() throws {
        try lock.withLock {
            recordedHealthCheckCount += 1
            if let healthFailure { throw healthFailure }
        }
    }

    func readSecret(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord? {
        try lock.withLock {
            recordedReadCount += 1
            if let readFailure { throw readFailure }
            guard let secret else { return nil }
            return LinuxSecretRecord(
                secret: secret,
                metadata: metadata(id: id, secretClass: secretClass)
            )
        }
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        lock.withLock {
            recordedStoreCount += 1
            self.secret = secret
        }
        return metadata(id: id, secretClass: secretClass)
    }

    func deleteSecret(id _: String, secretClass _: LinuxHighValueSecretClass) throws {
        lock.withLock {
            recordedDeleteCount += 1
            secret = nil
        }
    }

    private func metadata(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) -> LinuxSecretMetadata {
        LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 1_800_000_000_000,
            note: "test"
        )
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
