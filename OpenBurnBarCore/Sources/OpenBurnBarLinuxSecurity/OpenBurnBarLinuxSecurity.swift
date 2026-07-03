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
            #"(?i)(refresh[_-]?token|access[_-]?token|id[_-]?token|cookie|authorization)\s*[:=]\s*[^\s,;]+"#,
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
