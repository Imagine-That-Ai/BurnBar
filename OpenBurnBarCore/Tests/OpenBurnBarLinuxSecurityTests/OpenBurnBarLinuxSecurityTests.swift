import Foundation
@testable import OpenBurnBarLinuxSecurity
import XCTest

final class OpenBurnBarLinuxSecurityTests: XCTestCase {
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
            environment: ["OPENBURNBAR_FIREBASE_REFRESH_TOKEN": "refresh-token-value"]
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
        XCTAssertEqual(auditKey.metadata.trustLevel, .headlessPassphrase)
        XCTAssertTrue(auditKey.metadata.note.contains("systemd credentials"))
    }

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

        let custodian = LinuxSecretCustodian(backends: [
            LinuxInMemorySecretStoreBackend(
                backendName: "org.freedesktop.secrets.test",
                trustLevel: .secretService,
                secrets: ["firebase-refresh-token": "refresh-secret"]
            )
        ])
        let tokenStore = LinuxAuthTokenStore(custodian: custodian)
        XCTAssertEqual(try tokenStore.restoreRefreshToken().trustLevel, .secretService)

        let signOut = LinuxAuthSessionController(tokenStore: tokenStore) { metadata in
            XCTAssertEqual(metadata.backend, "org.freedesktop.secrets.test")
            XCTAssertEqual(metadata.secretClass, .refreshToken)
        }
        let signOutResult = try await signOut.signOut()
        XCTAssertTrue(signOutResult.remoteRevocationAttempted)
        XCTAssertTrue(signOutResult.localSessionCleared)
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
