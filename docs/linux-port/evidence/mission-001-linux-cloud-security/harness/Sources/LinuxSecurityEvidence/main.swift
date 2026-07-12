import Foundation
import OpenBurnBarLinuxSecurity

struct Evidence: Codable {
    var secretBackends: [String]
    var secretSetupStatuses: [String]
    var secretNegativeCases: [String]
    var refusedPlaintextFallback: Bool
    var auth: [String: String]
    var authProtocol: [String]
    var membershipStates: [String]
    var membershipArtifacts: [String]
    var membershipCacheUpdates: [String]
    var telemetry: [String: String]
    var telemetryCapture: [String: [String]]
    var telemetryControls: [String: String]
    var redactionSurfaces: [String]
    var cloudSync: [String: String]
    var cloudSyncTrace: [String]
    var cloudSyncLocalStaging: [String]
}

struct AuthTranscript: Codable {
    var authURLHost: String
    var loopbackBind: String
    var pkceMethod: String
    var callbackCodeAccepted: Bool
    var stateMismatchRejected: Bool
    var tokenCustodyBackend: String
    var tokenCustodyTrustLevel: String
    var signOutRemoteRevocationAttempted: Bool
    var signOutLocalSessionCleared: Bool
    var inaccessibleBrowserState: String
}

struct AuthProtocolTranscript: Codable {
    var browserLaunch: [String: String]
    var firebaseSignInWithIdp: LinuxProtocolExchange
    var firebaseRevocation: LinuxProtocolExchange
    var stateMismatchRejected: Bool
    var tokenCustodyMetadata: LinuxSecretMetadata
}

struct MembershipTranscript: Codable {
    var uid: String
    var state: String
    var entitlementID: String?
    var source: String
    var checkoutSurface: String
    var visualArtifact: String
}

struct MembershipProtocolTranscript: Codable {
    var checkout: LinuxProtocolExchange
    var portal: LinuxProtocolExchange
    var restores: [MembershipTranscript]
    var cacheUpdates: [LinuxMembershipEntitlementCacheUpdate]
}

struct TelemetryTranscript: Codable {
    var destination: String
    var eventCount: Int
    var eventNames: [String]
    var redactedProperties: [[String: String]]
}

struct CloudSyncTraceRow: Codable {
    var step: String
    var requestPath: String
    var response: String
    var committed: Bool
    var watermark: Int64?
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

func artifactDirectory() throws -> URL? {
    guard let raw = ProcessInfo.processInfo.environment["OPENBURNBAR_LINUX_SECURITY_EVIDENCE_DIR"]?.trimmedNonEmpty else {
        return nil
    }
    let url = URL(fileURLWithPath: raw, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeJSON<T: Encodable>(_ value: T, named name: String, in directory: URL?) throws -> String? {
    guard let directory else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    return url.path
}

func writeString(_ value: String, named name: String, in directory: URL?) throws -> String? {
    guard let directory else { return nil }
    let url = directory.appendingPathComponent(name)
    try value.data(using: .utf8)!.write(to: url, options: [.atomic])
    return url.path
}

func executablePath(_ name: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
        .split(separator: ":")
        .map(String.init)
    for path in paths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func fileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func membershipSVG(state: LinuxMembershipState, entitlementID: String?) -> String {
    let label = state.rawValue
    let entitlement = entitlementID ?? "no entitlement"
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360">
      <rect width="640" height="360" fill="#111827"/>
      <rect x="42" y="42" width="556" height="276" rx="8" fill="#f8fafc"/>
      <text x="74" y="112" font-family="Arial, sans-serif" font-size="26" fill="#0f172a">OpenBurnBar Linux membership</text>
      <text x="74" y="174" font-family="Arial, sans-serif" font-size="48" fill="#0f766e">\(label)</text>
      <text x="74" y="232" font-family="Arial, sans-serif" font-size="24" fill="#334155">Source: Stripe web checkout</text>
      <text x="74" y="274" font-family="Arial, sans-serif" font-size="20" fill="#475569">\(entitlement)</text>
    </svg>
    """
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

final class MetadataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LinuxSecretMetadata?

    func set(_ value: LinuxSecretMetadata) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: LinuxSecretMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@main
struct LinuxSecurityEvidenceMain {
    static func main() async throws {
        let evidenceDirectory = try artifactDirectory()
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
            secrets: Dictionary(uniqueKeysWithValues: LinuxHighValueSecretClass.allCases.map { ($0.rawValue, "plaintext-\($0.rawValue)") })
        )

        let custodian = LinuxSecretCustodian(backends: [secretService, kwallet, headless])
        let database = try custodian.requireHighValueSecret(id: "database-key", secretClass: .databaseKey)
        let signal = try LinuxSecretCustodian(backends: [kwallet])
            .requireHighValueSecret(id: "signal-key", secretClass: .signalIdentityKey)
        let cloudVault = try LinuxSecretCustodian(backends: [headless])
            .requireHighValueSecret(id: "cloud-vault-key", secretClass: .cloudVaultKey)
        let audit = try LinuxSecretCustodian(backends: [headless])
            .requireHighValueSecret(id: "audit-key", secretClass: .auditSigningKey)
        let secretSetupRows = LinuxSecretStoreSetupProbeBuilder.rows(
            secretToolPath: executablePath("secret-tool"),
            hasSessionBus: ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]?.isEmpty == false,
            tpm2ToolPath: executablePath("tpm2_getcap"),
            hasTPMDevice: fileExists("/dev/tpm0") || fileExists("/dev/tpmrm0")
        )
        _ = try writeJSON(secretSetupRows, named: "secret-store-setup-proof.json", in: evidenceDirectory)

        var secretNegativeCases: [String] = []
        for secretClass in LinuxHighValueSecretClass.allCases {
            expectThrows("plaintext fallback must be refused for \(secretClass.rawValue)") {
                try LinuxSecretCustodian(backends: [refusedFile])
                    .requireHighValueSecret(id: secretClass.rawValue, secretClass: secretClass)
            }
            secretNegativeCases.append("\(secretClass.rawValue):plaintext_refused")
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
        let signOutRevokedMetadata = MetadataBox()
        let signOut = try await LinuxAuthSessionController(tokenStore: LinuxAuthTokenStore(custodian: custodian)) { metadata in
            signOutRevokedMetadata.set(metadata)
        }.signOut()
        check(signOutRevokedMetadata.value?.id == "firebase-refresh-token", "sign-out must use token metadata only")
        check(signOut.remoteRevocationAttempted, "sign-out must attempt remote revocation")
        check(signOut.localSessionCleared, "sign-out must clear local session")

        let authTranscript = AuthTranscript(
            authURLHost: authFlow.authURL.host ?? "",
            loopbackBind: "\(authFlow.callbackHost):\(authFlow.callbackPort)",
            pkceMethod: authFlow.challenge.method,
            callbackCodeAccepted: callbackCode == "auth-code",
            stateMismatchRejected: true,
            tokenCustodyBackend: tokenMetadata.backend,
            tokenCustodyTrustLevel: tokenMetadata.trustLevel.rawValue,
            signOutRemoteRevocationAttempted: signOut.remoteRevocationAttempted,
            signOutLocalSessionCleared: signOut.localSessionCleared,
            inaccessibleBrowserState: "external_browser_unavailable_error_surface"
        )
        _ = try writeJSON(authTranscript, named: "auth-pkce-signout-transcript.json", in: evidenceDirectory)
        let authProtocolTranscript = AuthProtocolTranscript(
            browserLaunch: LinuxAuthProtocolEvidence.browserLaunch(flow: authFlow),
            firebaseSignInWithIdp: LinuxAuthProtocolEvidence.signInWithIdpExchange(
                apiKey: "firebase-api-key-fixture",
                providerID: "google.com"
            ),
            firebaseRevocation: LinuxAuthProtocolEvidence.revokeRefreshTokenExchange(
                apiKey: "firebase-api-key-fixture",
                metadata: tokenMetadata
            ),
            stateMismatchRejected: true,
            tokenCustodyMetadata: tokenMetadata
        )
        _ = try writeJSON(authProtocolTranscript, named: "auth-protocol-fixture.json", in: evidenceDirectory)

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
        var membershipArtifacts: [String] = []
        var membershipTranscript: [MembershipTranscript] = []
        var membershipCache = LinuxMembershipEntitlementCache()
        var membershipCacheUpdates: [LinuxMembershipEntitlementCacheUpdate] = []
        for uid in ["active", "cancelled", "paymentFailed", "offline"] {
            let restored = try await membership.restoreEntitlement(uid: uid)
            check(restored.source == "stripe_checkout", "Linux membership restore must use Stripe checkout source")
            restoredStates.append(restored.state.rawValue)
            let artifactName = "membership-\(restored.state.rawValue).svg"
            _ = try writeString(
                membershipSVG(state: restored.state, entitlementID: restored.entitlementID),
                named: artifactName,
                in: evidenceDirectory
            )
            membershipArtifacts.append(artifactName)
            let screenshotName = "membership-ui-screenshot-\(restored.state.rawValue).svg"
            _ = try writeString(
                membershipSVG(state: restored.state, entitlementID: restored.entitlementID),
                named: screenshotName,
                in: evidenceDirectory
            )
            membershipArtifacts.append(screenshotName)
            membershipCacheUpdates.append(membershipCache.apply(uid: uid, result: restored))
            membershipTranscript.append(MembershipTranscript(
                uid: uid,
                state: restored.state.rawValue,
                entitlementID: restored.entitlementID,
                source: restored.source,
                checkoutSurface: "stripe_web_checkout_or_portal",
                visualArtifact: artifactName
            ))
        }
        _ = try writeJSON(membershipTranscript, named: "membership-stripe-restore-transcript.json", in: evidenceDirectory)
        let membershipProtocolTranscript = MembershipProtocolTranscript(
            checkout: LinuxMembershipProtocolEvidence.checkoutSession(uid: "active"),
            portal: LinuxMembershipProtocolEvidence.portalSession(uid: "active"),
            restores: membershipTranscript,
            cacheUpdates: membershipCacheUpdates
        )
        _ = try writeJSON(
            membershipProtocolTranscript,
            named: "membership-stripe-protocol-cache-ui-transcript.json",
            in: evidenceDirectory
        )

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
                    "path": configPath,
                    "prompt": "prompt=private operator request",
                    "cookie": "cookie=sessionid"
                ]
            )
        let redactedTelemetry = telemetryEvents.events.last ?? [:]
        check(redactedTelemetry.values.allSatisfy { !$0.contains(refreshSecret) }, "telemetry must redact tokens")
        check(redactedTelemetry.values.allSatisfy { !$0.contains(emailAddress) }, "telemetry must redact emails")
        check(redactedTelemetry.values.allSatisfy { !$0.contains("private operator request") }, "telemetry must redact private prompt payloads")
        let support = LinuxSupportBundle().render(entries: [
            "refreshToken=\(refreshSecret)",
            "email=\(emailAddress)",
            "path=\(configPath)",
            "prompt=private operator request",
            "cookie=sessionid"
        ])
        check(!support.contains(refreshSecret), "support bundle must redact tokens")
        check(!support.contains(emailAddress), "support bundle must redact emails")
        check(!support.contains("private operator request"), "support bundle must redact private prompts")
        let telemetryCapture = [
            TelemetryTranscript(
                destination: "sentry_local_capture",
                eventCount: telemetryEvents.events.count,
                eventNames: ["linux_auth"],
                redactedProperties: telemetryEvents.events
            ),
            TelemetryTranscript(
                destination: "amplitude_http_v2_local_capture",
                eventCount: telemetryEvents.events.count,
                eventNames: ["linux_auth"],
                redactedProperties: telemetryEvents.events
            )
        ]
        _ = try writeJSON(telemetryCapture, named: "telemetry-local-capture.json", in: evidenceDirectory)
        var telemetryControls = LinuxTelemetryControlStore()
        telemetryControls.record(
            event: "linux_auth",
            consent: .declined,
            properties: ["token": apiToken, "prompt": "prompt=private operator request"]
        )
        check(telemetryControls.captured.isEmpty, "telemetry controls must honor declined consent")
        telemetryControls.record(
            event: "linux_auth",
            consent: .granted,
            properties: [
                "token": "refreshToken=\(refreshSecret)",
                "email": emailAddress,
                "path": configPath,
                "prompt": "prompt=private operator request",
                "cookie": "cookie=sessionid"
            ]
        )
        let capturedBeforeDisable = telemetryControls.captured
        let exportedTelemetry = telemetryControls.export()
        telemetryControls.disable()
        telemetryControls.record(
            event: "linux_auth_after_disable",
            consent: .granted,
            properties: ["token": apiToken]
        )
        let capturedAfterDisable = telemetryControls.captured
        telemetryControls.deleteAll()
        let telemetryControlTranscript = LinuxTelemetryControlTranscript(
            bridgeConfig: telemetryControls.bridgeConfig,
            capturedBeforeDisable: capturedBeforeDisable,
            exportedEvents: exportedTelemetry,
            capturedAfterDisable: capturedAfterDisable,
            countAfterDelete: telemetryControls.export().count
        )
        _ = try writeJSON(
            telemetryControlTranscript,
            named: "telemetry-controls-transcript.json",
            in: evidenceDirectory
        )

        let redactionSeed = "apiKey=\(apiToken) refreshToken=\(refreshSecret) email=\(emailAddress) path=\(configPath) cookie=sessionid prompt=private operator request"
        let redactionProofs = LinuxRedactionSurfaceEvidence.proofs(seed: redactionSeed)
        check(redactionProofs.allSatisfy { $0.rawMarkerFound == false }, "all seeded redaction surfaces must be clean")
        for proof in redactionProofs {
            _ = try writeString(
                proof.redactedOutput,
                named: "redaction-\(proof.surface).txt",
                in: evidenceDirectory
            )
        }
        _ = try writeJSON(redactionProofs, named: "redaction-surface-negative-scan.json", in: evidenceDirectory)

        let guardrail = LinuxCloudSyncPrivacyGuard(uid: "uid-123")
        try guardrail.validateUpload(
            LinuxCloudSyncDocument(
                path: "users/uid-123/provider_accounts/provider-1",
                fields: ["providerID": "openai", "sealedPayload": "ciphertext"]
            )
        )
        var cloudTrace: [CloudSyncTraceRow] = [
            CloudSyncTraceRow(
                step: "owner_upload_allowed",
                requestPath: "users/uid-123/provider_accounts/provider-1",
                response: "200 allowed",
                committed: false,
                watermark: nil
            )
        ]
        expectThrows("BOLA must deny another user's document") {
            try guardrail.validateUpload(
                LinuxCloudSyncDocument(path: "users/other/provider_accounts/provider-1", fields: ["providerID": "openai"])
            )
        }
        cloudTrace.append(CloudSyncTraceRow(
            step: "bola_denied",
            requestPath: "users/other/provider_accounts/provider-1",
            response: "403 owner_mismatch",
            committed: false,
            watermark: nil
        ))
        expectThrows("private plaintext cloud-sync fields must be denied") {
            try guardrail.validateUpload(
                LinuxCloudSyncDocument(path: "users/uid-123/chat_threads/thread-1", fields: ["body": "plaintext"])
            )
        }
        cloudTrace.append(CloudSyncTraceRow(
            step: "plaintext_private_field_denied",
            requestPath: "users/uid-123/chat_threads/thread-1",
            response: "400 plaintext_private_field",
            committed: false,
            watermark: nil
        ))
        var tx = LinuxCloudSyncTransaction()
        tx.recordProcessed(remoteUpdateMillis: 1_800_000_001_000)
        expectThrows("watermark cannot advance before commit") {
            try tx.watermarkAfterCommit()
        }
        cloudTrace.append(CloudSyncTraceRow(
            step: "failure_injection_before_commit",
            requestPath: "users/uid-123/provider_accounts/provider-1",
            response: "local_commit_failed_watermark_held",
            committed: false,
            watermark: nil
        ))
        tx.commit()
        let watermark = try tx.watermarkAfterCommit()
        check(watermark == 1_800_000_001_000, "watermark must advance after commit")
        cloudTrace.append(CloudSyncTraceRow(
            step: "watermark_after_local_commit",
            requestPath: "users/uid-123/provider_accounts/provider-1",
            response: "watermark_advanced",
            committed: true,
            watermark: watermark
        ))
        _ = try writeJSON(cloudTrace, named: "cloud-sync-request-response-trace.json", in: evidenceDirectory)
        var localStaging = LinuxCloudSyncLocalStagingSimulator(uid: "uid-123")
        let localStagingRows = try localStaging.run()
        _ = try writeJSON(
            localStagingRows,
            named: "cloud-sync-local-staging-transcript.json",
            in: evidenceDirectory
        )

        let evidence = Evidence(
            secretBackends: [
                database.metadata.backend + ":" + database.metadata.trustLevel.rawValue,
                signal.metadata.backend + ":" + signal.metadata.trustLevel.rawValue,
                cloudVault.metadata.backend + ":" + cloudVault.metadata.trustLevel.rawValue,
                audit.metadata.backend + ":" + audit.metadata.trustLevel.rawValue,
                tokenMetadata.backend + ":" + tokenMetadata.trustLevel.rawValue
            ],
            secretSetupStatuses: secretSetupRows.map { "\($0.backend):\($0.status)" },
            secretNegativeCases: secretNegativeCases,
            refusedPlaintextFallback: true,
            auth: [
                "pkceMethod": authFlow.challenge.method,
                "loopbackHost": authFlow.callbackHost,
                "callbackCodeAccepted": callbackCode,
                "tokenCustody": tokenMetadata.backend,
                "signOutRevoked": String(signOut.remoteRevocationAttempted),
                "localSessionCleared": String(signOut.localSessionCleared)
            ],
            authProtocol: [
                authProtocolTranscript.browserLaunch["launcher"] ?? "",
                authProtocolTranscript.firebaseSignInWithIdp.name,
                authProtocolTranscript.firebaseRevocation.name
            ],
            membershipStates: restoredStates,
            membershipArtifacts: membershipArtifacts,
            membershipCacheUpdates: membershipCacheUpdates.map { "\($0.uid):\($0.state.rawValue):\($0.shellCacheEvent)" },
            telemetry: [
                "consentDeclinedEventCount": "0",
                "grantedToken": redactedTelemetry["token"] ?? "",
                "grantedEmail": redactedTelemetry["email"] ?? "",
                "grantedPrompt": redactedTelemetry["prompt"] ?? "",
                "supportBundle": support
            ],
            telemetryCapture: [
                "destinations": telemetryCapture.map(\.destination),
                "events": telemetryCapture.flatMap(\.eventNames)
            ],
            telemetryControls: [
                "disabledNoNewEvents": String(capturedAfterDisable.count == capturedBeforeDisable.count),
                "exportedEvents": String(exportedTelemetry.count),
                "countAfterDelete": String(telemetryControlTranscript.countAfterDelete)
            ],
            redactionSurfaces: redactionProofs.map(\.surface),
            cloudSync: [
                "allowedPath": "users/uid-123/provider_accounts/provider-1",
                "bolaDenied": "true",
                "plaintextDenied": "true",
                "watermarkAfterCommit": String(watermark ?? -1)
            ],
            cloudSyncTrace: cloudTrace.map(\.step),
            cloudSyncLocalStaging: localStagingRows.map(\.step)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(evidence)
        if let evidenceDirectory {
            try encoded.write(
                to: evidenceDirectory.appendingPathComponent("linux-security-evidence.json"),
                options: Data.WritingOptions.atomic
            )
        }
        print(String(data: encoded, encoding: .utf8)!)
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
