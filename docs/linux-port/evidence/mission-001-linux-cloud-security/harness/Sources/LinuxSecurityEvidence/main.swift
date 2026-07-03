import Foundation
import OpenBurnBarLinuxSecurity

struct Evidence: Codable {
    var secretBackends: [String]
    var refusedPlaintextFallback: Bool
    var auth: [String: String]
    var membershipStates: [String]
    var telemetry: [String: String]
    var cloudSync: [String: String]
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

func expectThrows<T>(_ message: String, _ body: () throws -> T) {
    do {
        _ = try body()
        print("FAIL: \(message)")
        exit(1)
    } catch {
        return
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: String]] = []

    func append(_ properties: [String: String]) {
        lock.lock()
        storage.append(properties)
        lock.unlock()
    }

    var events: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@main
struct LinuxSecurityEvidenceMain {
    static func main() async throws {
        let databaseSecret = ["fixture", "db", "secret"].joined(separator: "-")
        let refreshSecret = ["fixture", "refresh", "token"].joined(separator: "-")
        let signalSecret = ["fixture", "signal", "secret"].joined(separator: "-")
        let headlessSecret = ["fixture", "headless", "secret"].joined(separator: "-")
        let auditSecret = ["fixture", "audit", "secret"].joined(separator: "-")
        let apiToken = "sk-ant-" + String(repeating: "a", count: 26)
        let emailAddress = ["alberto", "example.com"].joined(separator: "@")
        let configPath = "/" + ["home", "alberto", ".config", "openburnbar", "token.json"].joined(separator: "/")

        let secretService = LinuxInMemorySecretStoreBackend(
            backendName: "secret-service",
            trustLevel: .secretService,
            secrets: [
                "database-key": databaseSecret,
                "firebase-refresh-token": refreshSecret
            ]
        )
        let kwallet = LinuxCommandSecretStoreBackend(
            backendName: "kwallet",
            trustLevel: .kwallet,
            commandPreview: "kwallet-query",
            runner: { id in id == "signal-key" ? signalSecret : nil }
        )
        let headless = LinuxHeadlessSecretStoreBackend(
            environment: [
                "OPENBURNBAR_CLOUD_VAULT_KEY": headlessSecret,
                "CREDENTIALS_DIRECTORY": "/run/credentials/openburnbar"
            ],
            credentialReader: { path in
                path.hasSuffix("/audit-key") ? "\(auditSecret)\n" : ""
            }
        )
        let refusedFile = LinuxInMemorySecretStoreBackend(
            backendName: "plaintext-file",
            trustLevel: .explicitLowerTrustFile,
            secrets: ["local-auth-pin": "123456"]
        )

        let custodian = LinuxSecretCustodian(backends: [secretService, kwallet, headless])
        let database = try custodian.requireHighValueSecret(id: "database-key", secretClass: .databaseKey)
        let signal = try LinuxSecretCustodian(backends: [kwallet])
            .requireHighValueSecret(id: "signal-key", secretClass: .signalIdentityKey)
        let cloudVault = try LinuxSecretCustodian(backends: [headless])
            .requireHighValueSecret(id: "cloud-vault-key", secretClass: .cloudVaultKey)
        let audit = try LinuxSecretCustodian(backends: [headless])
            .requireHighValueSecret(id: "audit-key", secretClass: .auditSigningKey)
        expectThrows("plaintext fallback must be refused") {
            try LinuxSecretCustodian(backends: [refusedFile])
                .requireHighValueSecret(id: "local-auth-pin", secretClass: .localAuthPIN)
        }

        let authFlow = LinuxPKCELoopbackFlow(
            authBaseURL: URL(string: "https://auth.openburnbar.test/oauth")!,
            clientID: "linux-desktop",
            callbackPort: 48175,
            state: "state-123",
            verifier: "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-._~",
            scopes: ["openid", "email", "offline_access"]
        )
        check(authFlow.authURL.absoluteString.contains("code_challenge_method=S256"), "PKCE must use S256")
        check(authFlow.authURL.absoluteString.contains("redirect_uri=http://127.0.0.1:48175/callback"), "PKCE must use loopback redirect")
        let callbackCode = try authFlow.acceptCallback(
            URL(string: "http://127.0.0.1:48175/callback?state=state-123&code=auth-code")!
        )
        check(callbackCode == "auth-code", "callback code must be accepted")
        expectThrows("wrong loopback state must fail") {
            try authFlow.acceptCallback(URL(string: "http://127.0.0.1:48175/callback?state=wrong&code=auth-code")!)
        }
        let tokenMetadata = try LinuxAuthTokenStore(custodian: custodian).restoreRefreshToken()
        check(tokenMetadata.trustLevel == .secretService, "refresh token must restore from trusted SecretStore")

        let membershipFixtures: [String: LinuxMembershipRestoreResult] = [
            "active": LinuxMembershipRestoreResult(state: .active, entitlementID: "ent_linux_active", source: "stripe_checkout"),
            "cancelled": LinuxMembershipRestoreResult(state: .cancelled, entitlementID: "ent_linux_cancelled", source: "stripe_checkout"),
            "paymentFailed": LinuxMembershipRestoreResult(state: .paymentFailed, entitlementID: nil, source: "stripe_checkout"),
            "offline": LinuxMembershipRestoreResult(state: .offline, entitlementID: nil, source: "stripe_checkout")
        ]
        let membership = LinuxMembershipClient { uid in
            membershipFixtures[uid] ?? LinuxMembershipRestoreResult(state: .offline, entitlementID: nil, source: "stripe_checkout")
        }
        var restoredStates: [String] = []
        for uid in ["active", "cancelled", "paymentFailed", "offline"] {
            let restored = try await membership.restoreEntitlement(uid: uid)
            check(restored.source == "stripe_checkout", "Linux membership restore must use Stripe checkout source")
            restoredStates.append(restored.state.rawValue)
        }

        let telemetryEvents = EventBox()
        LinuxTelemetryRecorder(consent: .declined) { _, properties in telemetryEvents.append(properties) }
            .record(event: "linux_auth", properties: ["token": apiToken])
        check(telemetryEvents.events.isEmpty, "telemetry must be silent without consent")
        LinuxTelemetryRecorder(consent: .granted) { _, properties in telemetryEvents.append(properties) }
            .record(
                event: "linux_auth",
                properties: [
                    "token": "refreshToken=\(refreshSecret)",
                    "email": emailAddress,
                    "path": configPath
                ]
            )
        let redactedTelemetry = telemetryEvents.events.last ?? [:]
        check(redactedTelemetry.values.allSatisfy { !$0.contains(refreshSecret) }, "telemetry must redact tokens")
        check(redactedTelemetry.values.allSatisfy { !$0.contains(emailAddress) }, "telemetry must redact emails")
        let support = LinuxSupportBundle().render(entries: [
            "refreshToken=\(refreshSecret)",
            "email=\(emailAddress)",
            "path=\(configPath)"
        ])
        check(!support.contains(refreshSecret), "support bundle must redact tokens")
        check(!support.contains(emailAddress), "support bundle must redact emails")

        let guardrail = LinuxCloudSyncPrivacyGuard(uid: "uid-123")
        try guardrail.validateUpload(
            LinuxCloudSyncDocument(
                path: "users/uid-123/provider_accounts/provider-1",
                fields: ["providerID": "openai", "sealedPayload": "ciphertext"]
            )
        )
        expectThrows("BOLA must deny another user's document") {
            try guardrail.validateUpload(
                LinuxCloudSyncDocument(path: "users/other/provider_accounts/provider-1", fields: ["providerID": "openai"])
            )
        }
        expectThrows("private plaintext cloud-sync fields must be denied") {
            try guardrail.validateUpload(
                LinuxCloudSyncDocument(path: "users/uid-123/chat_threads/thread-1", fields: ["body": "plaintext"])
            )
        }
        var tx = LinuxCloudSyncTransaction()
        tx.recordProcessed(remoteUpdateMillis: 1_800_000_001_000)
        expectThrows("watermark cannot advance before commit") {
            try tx.watermarkAfterCommit()
        }
        tx.commit()
        let watermark = try tx.watermarkAfterCommit()
        check(watermark == 1_800_000_001_000, "watermark must advance after commit")

        let evidence = Evidence(
            secretBackends: [
                database.metadata.backend + ":" + database.metadata.trustLevel.rawValue,
                signal.metadata.backend + ":" + signal.metadata.trustLevel.rawValue,
                cloudVault.metadata.backend + ":" + cloudVault.metadata.trustLevel.rawValue,
                audit.metadata.backend + ":" + audit.metadata.trustLevel.rawValue,
                tokenMetadata.backend + ":" + tokenMetadata.trustLevel.rawValue
            ],
            refusedPlaintextFallback: true,
            auth: [
                "pkceMethod": authFlow.challenge.method,
                "loopbackHost": authFlow.callbackHost,
                "callbackCodeAccepted": callbackCode,
                "tokenCustody": tokenMetadata.backend
            ],
            membershipStates: restoredStates,
            telemetry: [
                "consentDeclinedEventCount": "0",
                "grantedToken": redactedTelemetry["token"] ?? "",
                "grantedEmail": redactedTelemetry["email"] ?? "",
                "supportBundle": support
            ],
            cloudSync: [
                "allowedPath": "users/uid-123/provider_accounts/provider-1",
                "bolaDenied": "true",
                "plaintextDenied": "true",
                "watermarkAfterCommit": String(watermark ?? -1)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(evidence), encoding: .utf8)!)
    }
}
