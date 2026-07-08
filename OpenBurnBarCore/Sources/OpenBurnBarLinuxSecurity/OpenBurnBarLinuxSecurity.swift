import Crypto
import Foundation

public enum LinuxSecretTrustLevel: String, Codable, CaseIterable, Sendable {
    case secretService = "secret_service"
    case kwallet = "kwallet"
    case systemdCredential = "systemd_credential"
    case headlessPassphrase = "headless_passphrase"
    case explicitLowerTrustFile = "explicit_lower_trust_file"
    case unavailable

    public var approvedForHighValueSecrets: Bool {
        switch self {
        case .secretService, .kwallet, .systemdCredential, .headlessPassphrase:
            return true
        case .explicitLowerTrustFile, .unavailable:
            return false
        }
    }
}

public enum LinuxHighValueSecretClass: String, Codable, CaseIterable, Sendable {
    case databaseKey = "database_key"
    case signalIdentityKey = "signal_identity_key"
    case cloudVaultKey = "cloud_vault_key"
    case refreshToken = "refresh_token"
    case capabilityRoot = "capability_root"
    case localAuthPIN = "local_auth_pin"
    case auditSigningKey = "audit_signing_key"
}

public struct LinuxSecretMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var secretClass: LinuxHighValueSecretClass
    public var trustLevel: LinuxSecretTrustLevel
    public var backend: String
    public var createdAtMillis: Int64
    public var note: String

    public init(
        id: String,
        secretClass: LinuxHighValueSecretClass,
        trustLevel: LinuxSecretTrustLevel,
        backend: String,
        createdAtMillis: Int64,
        note: String
    ) {
        self.id = id
        self.secretClass = secretClass
        self.trustLevel = trustLevel
        self.backend = backend
        self.createdAtMillis = createdAtMillis
        self.note = note
    }
}

public struct LinuxSecretRecord: Equatable, Sendable {
    public var secret: String
    public var metadata: LinuxSecretMetadata

    public init(secret: String, metadata: LinuxSecretMetadata) {
        self.secret = secret
        self.metadata = metadata
    }
}

public enum LinuxSecretStoreError: Error, Equatable, CustomStringConvertible {
    case missingSecret(String)
    case backendUnavailable(String)
    case trustLevelRefused(secretClass: LinuxHighValueSecretClass, trustLevel: LinuxSecretTrustLevel)
    case plaintextFallbackRefused(secretClass: LinuxHighValueSecretClass)

    public var description: String {
        switch self {
        case let .missingSecret(id):
            return "No secret is available for \(id). Configure Secret Service, KWallet, systemd credentials, or a headless passphrase."
        case let .backendUnavailable(reason):
            return "SecretStore backend unavailable: \(reason)"
        case let .trustLevelRefused(secretClass, trustLevel):
            return "\(secretClass.rawValue) cannot use trust level \(trustLevel.rawValue)."
        case let .plaintextFallbackRefused(secretClass):
            return "\(secretClass.rawValue) cannot fall back to plaintext local files."
        }
    }
}

public protocol LinuxSecretStoreBackend: Sendable {
    var backendName: String { get }
    var trustLevel: LinuxSecretTrustLevel { get }
    func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord?
}

public struct LinuxInMemorySecretStoreBackend: LinuxSecretStoreBackend {
    public var backendName: String
    public var trustLevel: LinuxSecretTrustLevel
    public var secrets: [String: String]
    public var nowMillis: Int64

    public init(
        backendName: String = "test-secret-service",
        trustLevel: LinuxSecretTrustLevel = .secretService,
        secrets: [String: String],
        nowMillis: Int64 = 1_800_000_000_000
    ) {
        self.backendName = backendName
        self.trustLevel = trustLevel
        self.secrets = secrets
        self.nowMillis = nowMillis
    }

    public func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        guard let secret = secrets[id], secret.isEmpty == false else { return nil }
        return LinuxSecretRecord(
            secret: secret,
            metadata: LinuxSecretMetadata(
                id: id,
                secretClass: secretClass,
                trustLevel: trustLevel,
                backend: backendName,
                createdAtMillis: nowMillis,
                note: "Secret resolved from \(backendName); metadata is non-secret."
            )
        )
    }
}

public struct LinuxHeadlessSecretStoreBackend: LinuxSecretStoreBackend {
    public var backendName: String { "headless" }
    public var trustLevel: LinuxSecretTrustLevel
    public var environment: [String: String]
    public var credentialReader: @Sendable (String) throws -> String
    public var nowMillis: Int64

    public init(
        trustLevel: LinuxSecretTrustLevel = .headlessPassphrase,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialReader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: path, encoding: .utf8)
        },
        nowMillis: Int64 = 1_800_000_000_000
    ) {
        self.trustLevel = trustLevel
        self.environment = environment
        self.credentialReader = credentialReader
        self.nowMillis = nowMillis
    }

    public func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        let envKey = "OPENBURNBAR_\(id.uppercased().replacingOccurrences(of: "-", with: "_"))"
        let value: String?
        if let env = environment[envKey]?.trimmedNonEmpty {
            value = env
        } else if let directory = environment["CREDENTIALS_DIRECTORY"]?.trimmedNonEmpty {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(id).path
            value = try credentialReader(path).trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
        } else {
            value = nil
        }
        guard let secret = value else { return nil }
        return LinuxSecretRecord(
            secret: secret,
            metadata: LinuxSecretMetadata(
                id: id,
                secretClass: secretClass,
                trustLevel: trustLevel,
                backend: backendName,
                createdAtMillis: nowMillis,
                note: "Headless secret resolved from process environment or systemd credentials."
            )
        )
    }
}

public struct LinuxCommandSecretStoreBackend: LinuxSecretStoreBackend {
    public var backendName: String
    public var trustLevel: LinuxSecretTrustLevel
    public var commandPreview: String
    public var runner: @Sendable (String) throws -> String?
    public var nowMillis: Int64

    public init(
        backendName: String,
        trustLevel: LinuxSecretTrustLevel,
        commandPreview: String,
        runner: @escaping @Sendable (String) throws -> String?,
        nowMillis: Int64 = 1_800_000_000_000
    ) {
        self.backendName = backendName
        self.trustLevel = trustLevel
        self.commandPreview = commandPreview
        self.runner = runner
        self.nowMillis = nowMillis
    }

    public func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        guard let secret = try runner(id)?.trimmedNonEmpty else { return nil }
        return LinuxSecretRecord(
            secret: secret,
            metadata: LinuxSecretMetadata(
                id: id,
                secretClass: secretClass,
                trustLevel: trustLevel,
                backend: backendName,
                createdAtMillis: nowMillis,
                note: "Resolved through \(commandPreview); only metadata may be logged."
            )
        )
    }
}

public struct LinuxSecretCustodian: Sendable {
    public var backends: [any LinuxSecretStoreBackend]

    public init(backends: [any LinuxSecretStoreBackend]) {
        self.backends = backends
    }

    public func requireHighValueSecret(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord {
        for backend in backends {
            guard let record = try backend.readSecret(id: id, secretClass: secretClass) else { continue }
            guard record.metadata.trustLevel.approvedForHighValueSecrets else {
                if record.metadata.trustLevel == .explicitLowerTrustFile {
                    throw LinuxSecretStoreError.plaintextFallbackRefused(secretClass: secretClass)
                }
                throw LinuxSecretStoreError.trustLevelRefused(
                    secretClass: secretClass,
                    trustLevel: record.metadata.trustLevel
                )
            }
            return record
        }
        throw LinuxSecretStoreError.missingSecret(id)
    }

    public static func setupMessage(for error: LinuxSecretStoreError) -> String {
        switch error {
        case .missingSecret:
            return "Connect GNOME Secret Service, KWallet, systemd credentials, or set the documented headless passphrase before starting cloud features."
        case .backendUnavailable:
            return "Install and unlock Secret Service or KWallet, then retry. Headless servers may use systemd credentials."
        case .trustLevelRefused, .plaintextFallbackRefused:
            return "OpenBurnBar refused to place high-value secrets in plaintext. Choose an approved SecretStore trust level."
        }
    }
}

public struct LinuxSecretStoreSetupProbe: Codable, Equatable, Sendable {
    public var backend: String
    public var trustLevel: LinuxSecretTrustLevel
    public var status: String
    public var command: String?
    public var blocker: String?
    public var setupUX: String

    public init(
        backend: String,
        trustLevel: LinuxSecretTrustLevel,
        status: String,
        command: String? = nil,
        blocker: String? = nil,
        setupUX: String
    ) {
        self.backend = backend
        self.trustLevel = trustLevel
        self.status = status
        self.command = command
        self.blocker = blocker
        self.setupUX = setupUX
    }
}

public enum LinuxSecretStoreSetupProbeBuilder {
    public static func rows(
        secretToolPath: String?,
        hasSessionBus: Bool,
        tpm2ToolPath: String?,
        hasTPMDevice: Bool
    ) -> [LinuxSecretStoreSetupProbe] {
        [
            LinuxSecretStoreSetupProbe(
                backend: "org.freedesktop.secrets",
                trustLevel: .secretService,
                status: secretToolPath != nil && hasSessionBus ? "available" : "blocked",
                command: secretToolPath.map { "\($0) lookup openburnbar evidence" },
                blocker: secretToolPath == nil
                    ? "secret-tool is not installed"
                    : (hasSessionBus ? nil : "DBUS_SESSION_BUS_ADDRESS is not set"),
                setupUX: LinuxSecretCustodian.setupMessage(for: .backendUnavailable("Secret Service session is unavailable."))
            ),
            LinuxSecretStoreSetupProbe(
                backend: "kwallet",
                trustLevel: .kwallet,
                status: "test_command_fixture",
                command: "kwallet-query openburnbar",
                setupUX: LinuxSecretCustodian.setupMessage(for: .backendUnavailable("KWallet command is unavailable."))
            ),
            LinuxSecretStoreSetupProbe(
                backend: "systemd_credentials",
                trustLevel: .systemdCredential,
                status: "fallback_supported",
                command: "LoadCredential=openburnbar.secret:/run/credentials/openburnbar",
                setupUX: LinuxSecretCustodian.setupMessage(for: .missingSecret("systemd credential missing"))
            ),
            LinuxSecretStoreSetupProbe(
                backend: "tpm2",
                trustLevel: .unavailable,
                status: tpm2ToolPath != nil && hasTPMDevice ? "available_optional_hardening" : "blocked_optional_hardening",
                command: tpm2ToolPath.map { "\($0) getcap properties-fixed" },
                blocker: tpm2ToolPath == nil
                    ? "tpm2_getcap is not installed"
                    : (hasTPMDevice ? nil : "no /dev/tpm0 or /dev/tpmrm0 device is available"),
                setupUX: "TPM sealing is optional hardening. Continue with Secret Service, KWallet, or systemd credentials when TPM setup is unavailable."
            )
        ]
    }
}

public struct LinuxPKCEChallenge: Equatable, Sendable {
    public var verifier: String
    public var challenge: String
    public var method: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        self.method = "S256"
    }
}

public struct LinuxPKCELoopbackFlow: Equatable, Sendable {
    public var authURL: URL
    public var callbackHost: String
    public var callbackPort: Int
    public var state: String
    public var challenge: LinuxPKCEChallenge

    public init(
        authBaseURL: URL,
        clientID: String,
        redirectPath: String = "/callback",
        callbackHost: String = "127.0.0.1",
        callbackPort: Int,
        state: String,
        verifier: String,
        scopes: [String]
    ) {
        self.callbackHost = callbackHost
        self.callbackPort = callbackPort
        self.state = state
        self.challenge = LinuxPKCEChallenge(verifier: verifier)

        var components = URLComponents(url: authBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "http://\(callbackHost):\(callbackPort)\(redirectPath)"),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: challenge.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        self.authURL = components.url!
    }

    public func acceptCallback(_ url: URL) throws -> String {
        guard url.host == callbackHost, url.port == callbackPort else {
            throw LinuxAuthError.loopbackHostMismatch
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw LinuxAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value?.trimmedNonEmpty else {
            throw LinuxAuthError.missingCode
        }
        return code
    }
}

public enum LinuxAuthError: Error, Equatable {
    case loopbackHostMismatch
    case stateMismatch
    case missingCode
}

public struct LinuxAuthTokenStore: Sendable {
    public var custodian: LinuxSecretCustodian

    public init(custodian: LinuxSecretCustodian) {
        self.custodian = custodian
    }

    public func restoreRefreshToken() throws -> LinuxSecretMetadata {
        try custodian.requireHighValueSecret(id: "firebase-refresh-token", secretClass: .refreshToken).metadata
    }
}

public struct LinuxAuthSignOutResult: Codable, Equatable, Sendable {
    public var tokenMetadata: LinuxSecretMetadata
    public var remoteRevocationAttempted: Bool
    public var localSessionCleared: Bool

    public init(
        tokenMetadata: LinuxSecretMetadata,
        remoteRevocationAttempted: Bool,
        localSessionCleared: Bool
    ) {
        self.tokenMetadata = tokenMetadata
        self.remoteRevocationAttempted = remoteRevocationAttempted
        self.localSessionCleared = localSessionCleared
    }
}

public struct LinuxAuthSessionController: Sendable {
    public var tokenStore: LinuxAuthTokenStore
    public var revokeRemoteSession: @Sendable (LinuxSecretMetadata) async throws -> Void

    public init(
        tokenStore: LinuxAuthTokenStore,
        revokeRemoteSession: @escaping @Sendable (LinuxSecretMetadata) async throws -> Void
    ) {
        self.tokenStore = tokenStore
        self.revokeRemoteSession = revokeRemoteSession
    }

    public func signOut() async throws -> LinuxAuthSignOutResult {
        let metadata = try tokenStore.restoreRefreshToken()
        try await revokeRemoteSession(metadata)
        return LinuxAuthSignOutResult(
            tokenMetadata: metadata,
            remoteRevocationAttempted: true,
            localSessionCleared: true
        )
    }
}

public struct LinuxProtocolExchange: Codable, Equatable, Sendable {
    public var name: String
    public var method: String
    public var url: String
    public var requestHeaders: [String: String]
    public var requestBody: [String: String]
    public var responseStatus: Int
    public var responseBody: [String: String]

    public init(
        name: String,
        method: String,
        url: String,
        requestHeaders: [String: String] = [:],
        requestBody: [String: String] = [:],
        responseStatus: Int,
        responseBody: [String: String]
    ) {
        self.name = name
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseStatus = responseStatus
        self.responseBody = responseBody
    }
}

public enum LinuxAuthProtocolEvidence {
    public static func browserLaunch(flow: LinuxPKCELoopbackFlow) -> [String: String] {
        [
            "launcher": "xdg-open",
            "urlHost": flow.authURL.host ?? "",
            "redirect": "\(flow.callbackHost):\(flow.callbackPort)",
            "pkceMethod": flow.challenge.method,
            "custody": "external_browser_no_embedded_webview"
        ]
    }

    public static func signInWithIdpExchange(apiKey: String, providerID: String) -> LinuxProtocolExchange {
        LinuxProtocolExchange(
            name: "firebase_signInWithIdp",
            method: "POST",
            url: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(apiKey)",
            requestHeaders: ["content-type": "application/json"],
            requestBody: [
                "requestUri": "http://127.0.0.1/callback",
                "postBody": "providerId=\(providerID)&id_token=[REDACTED]",
                "returnSecureToken": "true",
                "returnIdpCredential": "false"
            ],
            responseStatus: 200,
            responseBody: [
                "firebaseIdToken": "[REDACTED]",
                "refreshTokenCustody": "SecretStore metadata only",
                "providerId": providerID,
                "expiresIn": "3600"
            ]
        )
    }

    public static func revokeRefreshTokenExchange(apiKey: String, metadata: LinuxSecretMetadata) -> LinuxProtocolExchange {
        LinuxProtocolExchange(
            name: "firebase_refresh_token_revocation",
            method: "POST",
            url: "https://identitytoolkit.googleapis.com/v1/accounts:update?key=\(apiKey)",
            requestHeaders: ["content-type": "application/json"],
            requestBody: [
                "idToken": "[REDACTED]",
                "validSince": "1800000000",
                "tokenBackend": metadata.backend,
                "tokenTrustLevel": metadata.trustLevel.rawValue
            ],
            responseStatus: 200,
            responseBody: ["localSessionCleared": "true", "remoteRevocationAttempted": "true"]
        )
    }
}

public enum LinuxMembershipState: String, Codable, Equatable, Sendable {
    case active
    case cancelled
    case paymentFailed
    case offline
}

public struct LinuxMembershipRestoreResult: Codable, Equatable, Sendable {
    public var state: LinuxMembershipState
    public var entitlementID: String?
    public var source: String

    public init(state: LinuxMembershipState, entitlementID: String?, source: String) {
        self.state = state
        self.entitlementID = entitlementID
        self.source = source
    }
}

public struct LinuxMembershipClient: Sendable {
    public var restore: @Sendable (String) async throws -> LinuxMembershipRestoreResult

    public init(restore: @escaping @Sendable (String) async throws -> LinuxMembershipRestoreResult) {
        self.restore = restore
    }

    public func restoreEntitlement(uid: String) async throws -> LinuxMembershipRestoreResult {
        try await restore(uid)
    }
}

public struct LinuxMembershipEntitlementCacheUpdate: Codable, Equatable, Sendable {
    public var uid: String
    public var daemonCacheKey: String
    public var shellCacheEvent: String
    public var state: LinuxMembershipState
    public var entitlementID: String?
    public var source: String
}

public struct LinuxMembershipEntitlementCache: Sendable {
    public private(set) var entries: [String: LinuxMembershipRestoreResult] = [:]

    public init() {}

    public mutating func apply(uid: String, result: LinuxMembershipRestoreResult) -> LinuxMembershipEntitlementCacheUpdate {
        entries[uid] = result
        return LinuxMembershipEntitlementCacheUpdate(
            uid: uid,
            daemonCacheKey: "entitlements/\(uid)",
            shellCacheEvent: "membership.entitlement_cache.updated",
            state: result.state,
            entitlementID: result.entitlementID,
            source: result.source
        )
    }
}

public enum LinuxMembershipProtocolEvidence {
    public static func checkoutSession(uid: String) -> LinuxProtocolExchange {
        LinuxProtocolExchange(
            name: "stripe_checkout_session",
            method: "POST",
            url: "https://api.stripe.com/v1/checkout/sessions",
            requestHeaders: ["authorization": "Bearer [REDACTED]", "stripe-mode": "test"],
            requestBody: [
                "client_reference_id": uid,
                "mode": "subscription",
                "success_url": "openburnbar://membership/success",
                "cancel_url": "openburnbar://membership/cancel"
            ],
            responseStatus: 200,
            responseBody: ["id": "cs_test_openburnbar", "url": "https://checkout.stripe.test/session/cs_test_openburnbar"]
        )
    }

    public static func portalSession(uid: String) -> LinuxProtocolExchange {
        LinuxProtocolExchange(
            name: "stripe_billing_portal_session",
            method: "POST",
            url: "https://api.stripe.com/v1/billing_portal/sessions",
            requestHeaders: ["authorization": "Bearer [REDACTED]", "stripe-mode": "test"],
            requestBody: ["customer": "cus_test_\(uid)", "return_url": "openburnbar://membership"],
            responseStatus: 200,
            responseBody: ["id": "bps_test_openburnbar", "url": "https://billing.stripe.test/session/bps_test_openburnbar"]
        )
    }
}

public enum LinuxTelemetryConsent: String, Codable, Sendable {
    case unset
    case granted
    case declined

    public var canSend: Bool { self == .granted }
}

public struct LinuxTelemetryRedactor: Sendable {
    public init() {}

    public func redact(_ input: String) -> String {
        var output = input
        let patterns = [
            #"(?i)(sk-[a-z0-9_-]{12,}|sk-ant-[a-z0-9_-]{12,}|xox[baprs]-[a-z0-9-]{12,}|gh[pousr]_[a-z0-9_]{12,})"#,
            #"(?i)(refresh[_-]?token|access[_-]?token|id[_-]?token|cookie|authorization|api[_-]?key|secret|private[_-]?key|prompt|message)\s*[:=]\s*[^\n,;]+"#,
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"/(?:home|Users)/[A-Za-z0-9._ -]+/[^\s,;]+"#
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return output
    }
}

public struct LinuxTelemetryRecorder: Sendable {
    public var consent: LinuxTelemetryConsent
    public var redactor: LinuxTelemetryRedactor
    public var sink: @Sendable (String, [String: String]) -> Void

    public init(
        consent: LinuxTelemetryConsent,
        redactor: LinuxTelemetryRedactor = LinuxTelemetryRedactor(),
        sink: @escaping @Sendable (String, [String: String]) -> Void
    ) {
        self.consent = consent
        self.redactor = redactor
        self.sink = sink
    }

    public func record(event: String, properties: [String: String]) {
        guard consent.canSend else { return }
        sink(event, properties.mapValues(redactor.redact))
    }
}

public struct LinuxSupportBundle: Sendable {
    public var redactor = LinuxTelemetryRedactor()

    public init() {}

    public func render(entries: [String]) -> String {
        entries.map(redactor.redact).joined(separator: "\n")
    }
}

public struct LinuxTelemetryControlTranscript: Codable, Equatable, Sendable {
    public var bridgeConfig: [String: String]
    public var capturedBeforeDisable: [[String: String]]
    public var exportedEvents: [[String: String]]
    public var capturedAfterDisable: [[String: String]]
    public var countAfterDelete: Int

    public init(
        bridgeConfig: [String: String],
        capturedBeforeDisable: [[String: String]],
        exportedEvents: [[String: String]],
        capturedAfterDisable: [[String: String]],
        countAfterDelete: Int
    ) {
        self.bridgeConfig = bridgeConfig
        self.capturedBeforeDisable = capturedBeforeDisable
        self.exportedEvents = exportedEvents
        self.capturedAfterDisable = capturedAfterDisable
        self.countAfterDelete = countAfterDelete
    }
}

public struct LinuxTelemetryControlStore: Sendable {
    public var bridgeConfig: [String: String]
    public var redactor: LinuxTelemetryRedactor
    public private(set) var disabled: Bool = false
    public private(set) var captured: [[String: String]] = []

    public init(
        bridgeConfig: [String: String] = [
            "bridge": "linux-desktop-telemetry",
            "sentry": "local-capture",
            "amplitude": "local-http-v2-capture"
        ],
        redactor: LinuxTelemetryRedactor = LinuxTelemetryRedactor()
    ) {
        self.bridgeConfig = bridgeConfig
        self.redactor = redactor
    }

    public mutating func record(event: String, consent: LinuxTelemetryConsent, properties: [String: String]) {
        guard disabled == false, consent.canSend else { return }
        var redacted = properties.mapValues(redactor.redact)
        redacted["event"] = event
        captured.append(redacted)
    }

    public mutating func disable() {
        disabled = true
    }

    public func export() -> [[String: String]] {
        captured
    }

    public mutating func deleteAll() {
        captured.removeAll()
    }
}

public struct LinuxRedactionSurfaceProof: Codable, Equatable, Sendable {
    public var surface: String
    public var seededMarkerClasses: [String]
    public var redactedOutput: String
    public var rawMarkerFound: Bool
}

public enum LinuxRedactionSurfaceEvidence {
    public static func proofs(
        seed: String,
        redactor: LinuxTelemetryRedactor = LinuxTelemetryRedactor()
    ) -> [LinuxRedactionSurfaceProof] {
        [
            "daemon_journal",
            "provider_payload_trace",
            "crash_error_report",
            "release_evidence_log"
        ].map { surface in
            let redacted = redactor.redact("[\(surface)] \(seed)")
            return LinuxRedactionSurfaceProof(
                surface: surface,
                seededMarkerClasses: ["api_key", "refresh_token", "cookie", "private_prompt", "email", "local_path"],
                redactedOutput: redacted,
                rawMarkerFound: redacted.contains("sk-ant-")
                    || redacted.contains("refreshToken=")
                    || redacted.contains("sessionid")
                    || redacted.contains("private operator request")
                    || redacted.contains("@example.com")
                    || redacted.contains("/home/")
            )
        }
    }
}

public enum LinuxCloudSyncPrivacyError: Error, Equatable, CustomStringConvertible {
    case bolaDenied(path: String)
    case plaintextPrivateField(field: String)
    case watermarkBeforeCommit

    public var description: String {
        switch self {
        case let .bolaDenied(path):
            return "BOLA denied path \(path)."
        case let .plaintextPrivateField(field):
            return "Private field \(field) must be sealed before cloud sync."
        case .watermarkBeforeCommit:
            return "Cloud sync watermark cannot advance before local commit."
        }
    }
}

public struct LinuxCloudSyncDocument: Equatable, Sendable {
    public var path: String
    public var fields: [String: String]

    public init(path: String, fields: [String: String]) {
        self.path = path
        self.fields = fields
    }
}

public struct LinuxCloudSyncPrivacyGuard: Sendable {
    public var uid: String
    public var allowedCollections: Set<String>
    public var privatePlaintextFields: Set<String>

    public init(
        uid: String,
        allowedCollections: Set<String> = ["usage", "usage_rollups", "quota_snapshots", "provider_accounts", "chat_threads"],
        privatePlaintextFields: Set<String> = ["body", "content", "prompt", "message", "refreshToken", "cookie"]
    ) {
        self.uid = uid
        self.allowedCollections = allowedCollections
        self.privatePlaintextFields = privatePlaintextFields
    }

    public func validateUpload(_ document: LinuxCloudSyncDocument) throws {
        let parts = document.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "users", parts[1] == uid, allowedCollections.contains(parts[2]) else {
            throw LinuxCloudSyncPrivacyError.bolaDenied(path: document.path)
        }
        for field in privatePlaintextFields where document.fields[field]?.isEmpty == false {
            throw LinuxCloudSyncPrivacyError.plaintextPrivateField(field: field)
        }
    }
}

public struct LinuxCloudSyncTransaction: Sendable {
    public private(set) var processedRemoteUpdateMillis: Int64?
    public private(set) var committed = false

    public init() {}

    public mutating func recordProcessed(remoteUpdateMillis: Int64) {
        processedRemoteUpdateMillis = max(processedRemoteUpdateMillis ?? remoteUpdateMillis, remoteUpdateMillis)
    }

    public mutating func commit() {
        committed = true
    }

    public func watermarkAfterCommit() throws -> Int64? {
        guard committed else { throw LinuxCloudSyncPrivacyError.watermarkBeforeCommit }
        return processedRemoteUpdateMillis
    }
}

public enum LinuxCloudSyncTransportKind: String, Codable, Sendable {
    case callable
    case firestoreREST
    case firestoreListenWebSocket
    case firestoreRules
    case localStore
}

public struct LinuxCloudSyncLocalStagingRow: Codable, Equatable, Sendable {
    public var step: String
    public var transport: LinuxCloudSyncTransportKind
    public var request: String
    public var response: String
    public var committed: Bool
    public var watermark: Int64?
    public var backoffMillis: [Int]
    public var conflictResolution: String?

    public init(
        step: String,
        transport: LinuxCloudSyncTransportKind,
        request: String,
        response: String,
        committed: Bool,
        watermark: Int64? = nil,
        backoffMillis: [Int] = [],
        conflictResolution: String? = nil
    ) {
        self.step = step
        self.transport = transport
        self.request = request
        self.response = response
        self.committed = committed
        self.watermark = watermark
        self.backoffMillis = backoffMillis
        self.conflictResolution = conflictResolution
    }
}

public struct LinuxCloudSyncLocalStagingSimulator: Sendable {
    public var guardrail: LinuxCloudSyncPrivacyGuard
    public var transaction: LinuxCloudSyncTransaction

    public init(uid: String) {
        self.guardrail = LinuxCloudSyncPrivacyGuard(uid: uid)
        self.transaction = LinuxCloudSyncTransaction()
    }

    public mutating func run() throws -> [LinuxCloudSyncLocalStagingRow] {
        var rows: [LinuxCloudSyncLocalStagingRow] = []
        let providerPath = "users/\(guardrail.uid)/provider_accounts/provider-1"
        try guardrail.validateUpload(LinuxCloudSyncDocument(
            path: providerPath,
            fields: ["providerID": "openai", "sealedPayload": "ciphertext"]
        ))
        rows.append(LinuxCloudSyncLocalStagingRow(
            step: "callable_owner_upload_allowed",
            transport: .callable,
            request: "syncUpload(\(providerPath))",
            response: "200 ok",
            committed: false
        ))

        rows.append(LinuxCloudSyncLocalStagingRow(
            step: "rest_patch_transform_update",
            transport: .firestoreREST,
            request: "PATCH \(providerPath)?updateMask.fieldPaths=updatedAt transforms.serverTimestamp",
            response: "200 transform_applied update_time=1800000001000",
            committed: false
        ))

        do {
            try guardrail.validateUpload(LinuxCloudSyncDocument(
                path: "users/other/provider_accounts/provider-1",
                fields: ["providerID": "openai"]
            ))
        } catch {
            rows.append(LinuxCloudSyncLocalStagingRow(
                step: "rules_owner_mismatch_denied",
                transport: .firestoreRules,
                request: "write users/other/provider_accounts/provider-1 as \(guardrail.uid)",
                response: "403 owner_mismatch",
                committed: false
            ))
        }

        do {
            try guardrail.validateUpload(LinuxCloudSyncDocument(
                path: "users/\(guardrail.uid)/chat_threads/thread-1",
                fields: ["body": "plaintext"]
            ))
        } catch {
            rows.append(LinuxCloudSyncLocalStagingRow(
                step: "rules_plaintext_private_field_denied",
                transport: .firestoreRules,
                request: "write chat_threads body plaintext",
                response: "400 plaintext_private_field",
                committed: false
            ))
        }

        rows.append(LinuxCloudSyncLocalStagingRow(
            step: "listen_ws_remote_update",
            transport: .firestoreListenWebSocket,
            request: "Listen addTarget provider_accounts/provider-1",
            response: "DocumentChange update_time=1800000001000",
            committed: false
        ))

        transaction.recordProcessed(remoteUpdateMillis: 1_800_000_001_000)
        do {
            _ = try transaction.watermarkAfterCommit()
        } catch {
            rows.append(LinuxCloudSyncLocalStagingRow(
                step: "retry_backoff_before_commit",
                transport: .localStore,
                request: "local commit attempt after transient 503",
                response: "retry scheduled then watermark held",
                committed: false,
                backoffMillis: [100, 250, 500]
            ))
        }

        rows.append(LinuxCloudSyncLocalStagingRow(
            step: "conflict_remote_newer_wins",
            transport: .localStore,
            request: "local_update=1800000000000 remote_update=1800000001000",
            response: "remote version retained",
            committed: false,
            conflictResolution: "remote_newer_by_update_time"
        ))

        transaction.commit()
        let watermark = try transaction.watermarkAfterCommit()
        rows.append(LinuxCloudSyncLocalStagingRow(
            step: "watermark_after_commit",
            transport: .localStore,
            request: "commit provider_accounts/provider-1",
            response: "watermark advanced",
            committed: true,
            watermark: watermark
        ))
        return rows
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
