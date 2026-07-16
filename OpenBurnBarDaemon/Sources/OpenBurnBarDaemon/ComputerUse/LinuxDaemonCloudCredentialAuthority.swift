#if os(Linux)
import Foundation
import OpenBurnBarIrohRelay
import OpenBurnBarKernel
import OpenBurnBarLinuxSecurity
import Glibc

public struct LinuxCloudAuthConfiguration: Sendable, Equatable {
    public let googleOAuthClientID: String
    public let googleOAuthClientSecret: String?
    public let firebaseAPIKey: String
    public let linuxAppCheckAppID: String
    public let authorizationEndpoint: URL
    public let googleTokenEndpoint: URL
    public let firebaseSignInEndpoint: URL
    public let firebaseRefreshEndpoint: URL
    public let functionsBaseURL: URL
    public let authorizationTimeout: TimeInterval

    public init(
        googleOAuthClientID: String,
        googleOAuthClientSecret: String? = nil,
        firebaseAPIKey: String,
        linuxAppCheckAppID: String,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        googleTokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        firebaseSignInEndpoint: URL = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp")!,
        firebaseRefreshEndpoint: URL = URL(string: "https://securetoken.googleapis.com/v1/token")!,
        functionsBaseURL: URL = URL(string: "https://us-central1-burnbar.cloudfunctions.net")!,
        authorizationTimeout: TimeInterval = 180
    ) {
        self.googleOAuthClientID = googleOAuthClientID
        self.googleOAuthClientSecret = googleOAuthClientSecret
        self.firebaseAPIKey = firebaseAPIKey
        self.linuxAppCheckAppID = linuxAppCheckAppID
        self.authorizationEndpoint = authorizationEndpoint
        self.googleTokenEndpoint = googleTokenEndpoint
        self.firebaseSignInEndpoint = firebaseSignInEndpoint
        self.firebaseRefreshEndpoint = firebaseRefreshEndpoint
        self.functionsBaseURL = functionsBaseURL
        self.authorizationTimeout = authorizationTimeout
    }

    public static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        let environmentKeys = [
            "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID",
            "OPENBURNBAR_FIREBASE_API_KEY",
            "OPENBURNBAR_LINUX_APP_CHECK_APP_ID"
        ]
        if environmentKeys.contains(where: { environment[$0]?.trimmed != nil }) {
            guard let clientID = environment[environmentKeys[0]]?.trimmed,
                  let apiKey = environment[environmentKeys[1]]?.trimmed,
                  let appID = environment[environmentKeys[2]]?.trimmed,
                  validGoogleOAuthClientID(clientID),
                  validFirebaseAPIKey(apiKey),
                  validLinuxAppCheckAppID(appID) else { return nil }
            return Self(
                googleOAuthClientID: clientID,
                googleOAuthClientSecret: environment["OPENBURNBAR_GOOGLE_OAUTH_CLIENT_SECRET"]?.trimmed,
                firebaseAPIKey: apiKey,
                linuxAppCheckAppID: appID
            )
        }

        if let explicitPath = environment["OPENBURNBAR_CLOUD_AUTH_CONFIG_FILE"]?.trimmed {
            guard case let .loaded(values) = loadPublicConfiguration(
                path: explicitPath,
                ownership: .explicitUserOrRoot
            ) else { return nil }
            return values
        }
        if let packagedPath = environment["OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE"]?.trimmed {
            switch loadPublicConfiguration(path: packagedPath, ownership: .systemRoot) {
            case let .loaded(values): return values
            case .missing: break
            case .invalid: return nil
            }
        }
        for path in ["/etc/openburnbar/cloud-auth.json", "/usr/share/openburnbar/cloud-auth.json"] {
            switch loadPublicConfiguration(path: path, ownership: .systemRoot) {
            case let .loaded(values): return values
            case .missing: continue
            case .invalid: return nil
            }
        }
        return nil
    }

    private enum ConfigurationOwnership { case explicitUserOrRoot, systemRoot }
    private enum ConfigurationLoad { case loaded(LinuxCloudAuthConfiguration), missing, invalid }

    private struct PackagedConfiguration: Decodable {
        let schemaVersion: Int
        let configured: Bool
        let googleOAuthClientID: String?
        let firebaseAPIKey: String?
        let linuxAppCheckAppID: String?
    }

    private static func loadPublicConfiguration(
        path: String,
        ownership: ConfigurationOwnership
    ) -> ConfigurationLoad {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return .invalid }
        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 { return errno == ENOENT ? .missing : .invalid }
        defer { _ = Glibc.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= 16 * 1_024 else { return .invalid }
        switch ownership {
        case .systemRoot:
            guard metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else { return .invalid }
        case .explicitUserOrRoot:
            guard metadata.st_uid == 0 || metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0 else { return .invalid }
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Glibc.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .invalid
            }
            guard data.count <= 16 * 1_024 - Int(count) else { return .invalid }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let packaged = try? JSONDecoder().decode(PackagedConfiguration.self, from: data),
              packaged.schemaVersion == 1 else { return .invalid }
        let envelopeKeys = Set(["schemaVersion", "configured"])
        if packaged.configured == false {
            return Set(dictionary.keys) == envelopeKeys ? .missing : .invalid
        }
        let configuredKeys = envelopeKeys.union([
            "googleOAuthClientID", "firebaseAPIKey", "linuxAppCheckAppID"
        ])
        guard Set(dictionary.keys) == configuredKeys,
              let clientID = packaged.googleOAuthClientID?.trimmed,
              let apiKey = packaged.firebaseAPIKey?.trimmed,
              let appID = packaged.linuxAppCheckAppID?.trimmed,
              validGoogleOAuthClientID(clientID),
              validFirebaseAPIKey(apiKey),
              validLinuxAppCheckAppID(appID) else { return .invalid }
        return .loaded(Self(
            googleOAuthClientID: clientID,
            firebaseAPIKey: apiKey,
            linuxAppCheckAppID: appID
        ))
    }

    fileprivate static func validPublicValue(_ value: String) -> Bool {
        guard value.utf8.count >= 8, value.utf8.count <= 512,
              value.contains("\0") == false,
              value.contains("\n") == false,
              value.contains("\r") == false else { return false }
        let lowered = value.lowercased()
        return lowered.contains("placeholder") == false
            && lowered.contains("replace_with") == false
            && lowered.contains("your_") == false
    }

    fileprivate static func validGoogleOAuthClientID(_ value: String) -> Bool {
        validPublicValue(value)
            && value.range(
                of: #"^[A-Za-z0-9._-]{12,512}\.apps\.googleusercontent\.com$"#,
                options: .regularExpression
            ) != nil
    }

    fileprivate static func validFirebaseAPIKey(_ value: String) -> Bool {
        validPublicValue(value)
            && value.range(of: #"^AIza[A-Za-z0-9_-]{20,196}$"#, options: .regularExpression) != nil
    }

    fileprivate static func validLinuxAppCheckAppID(_ value: String) -> Bool {
        validPublicValue(value)
            && value.range(
                of: #"^1:[0-9]{6,20}:(?:linux|web):[A-Za-z0-9_-]{8,128}$"#,
                options: .regularExpression
            ) != nil
    }
}

struct LinuxCloudAuthStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case configurationRequired = "configuration_required"
        case signedOut = "signed_out"
        case authorizing
        case awaitingDeviceApproval = "awaiting_device_approval"
        case refreshing
        case ready
        case locked
        case error
    }

    let phase: Phase
    let operationID: String?
    let operationExpiresAt: Date?
    let hasStoredSession: Bool
    let reasonCode: String?

    init(
        phase: Phase,
        operationID: String? = nil,
        operationExpiresAt: Date? = nil,
        hasStoredSession: Bool,
        reasonCode: String? = nil
    ) {
        self.phase = phase
        self.operationID = operationID
        self.operationExpiresAt = operationExpiresAt
        self.hasStoredSession = hasStoredSession
        self.reasonCode = reasonCode
    }
}

private struct LinuxStoredFirebaseSession: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let refreshToken: String
    let uid: String?
    let identityLabel: String?

    static func decode(_ value: String) throws -> Self {
        guard value.utf8.count <= 16_384,
              value.isEmpty == false,
              value.contains("\n") == false,
              value.contains("\r") == false else {
            throw LinuxSecretStoreError.invalidSecretValue("invalid Firebase session record")
        }
        guard value.first == "{" else {
            return Self(
                schemaVersion: currentSchemaVersion,
                refreshToken: value,
                uid: nil,
                identityLabel: nil
            )
        }
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == currentSchemaVersion,
              Self.validToken(decoded.refreshToken),
              decoded.uid.map(Self.validUID) ?? true,
              decoded.identityLabel.map(Self.validIdentityLabel) ?? true,
              decoded.identityLabel == nil || decoded.uid != nil else {
            throw LinuxSecretStoreError.invalidSecretValue("invalid Firebase session envelope")
        }
        return decoded
    }

    func encoded() throws -> String {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.validToken(refreshToken),
              uid.map(Self.validUID) ?? true,
              identityLabel.map(Self.validIdentityLabel) ?? true,
              identityLabel == nil || uid != nil else {
            throw LinuxSecretStoreError.invalidSecretValue("invalid Firebase session envelope")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 16_384, let value = String(data: data, encoding: .utf8) else {
            throw LinuxSecretStoreError.invalidSecretValue("invalid Firebase session envelope")
        }
        return value
    }

    static func validToken(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 16_384
            && value.contains("\n") == false && value.contains("\r") == false
    }

    static func validUID(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 256
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }

    static func validIdentityLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value && value.isEmpty == false && value.utf8.count <= 320
            && value.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
    }
}

public enum LinuxCloudAuthSessionEvent: Sendable, Equatable {
    case credentialsAvailable
    case invalidated
}

public enum LinuxCloudAuthAuthorityError: Error, Equatable, Sendable, CustomStringConvertible {
    case configurationRequired
    case notSignedIn
    case authorizationInProgress
    case operationMismatch
    case authorizationFailed
    case deviceApprovalRequired
    case deviceRejected
    case appCheckConfigurationRejected
    case reauthorizationRequired
    case cloudResponseInvalid
    case secureStoreUnavailable
    case installationIdentityUnavailable
    case sessionChanged
    case cloudUnavailable
    case trustedDeviceBridgeUnavailable
    case dataControlInProgress
    case trustedDeviceAuthorizationRejected
    case dataControlAuthorizationInvalid

    public var description: String {
        switch self {
        case .configurationRequired: "Linux cloud authentication is not configured."
        case .notSignedIn: "Sign in before using cloud Computer Use."
        case .authorizationInProgress: "A sign-in operation is already in progress."
        case .operationMismatch: "The sign-in operation is no longer active."
        case .authorizationFailed: "The browser sign-in could not be completed."
        case .deviceApprovalRequired: "Approve this Linux installation from a trusted OpenBurnBar device."
        case .deviceRejected: "This Linux installation was rejected or revoked and must be enrolled with a new key."
        case .appCheckConfigurationRejected: "This build's Linux App Check application is not allowlisted."
        case .reauthorizationRequired: "The cloud session expired. Sign in again to continue."
        case .cloudResponseInvalid: "The cloud authentication service returned an invalid response."
        case .secureStoreUnavailable: "Unlock an approved Linux SecretStore backend and retry."
        case .installationIdentityUnavailable: "The Linux installation identity is unavailable or corrupt."
        case .sessionChanged: "The account session changed while credentials were refreshing."
        case .cloudUnavailable: "The OpenBurnBar cloud authentication service is unavailable."
        case .trustedDeviceBridgeUnavailable: "A trusted-device approval bridge is not connected on this Linux installation."
        case .dataControlInProgress: "Another cloud data-control request is already waiting for approval."
        case .trustedDeviceAuthorizationRejected: "The trusted device rejected or could not complete this cloud data-control request."
        case .dataControlAuthorizationInvalid: "The trusted-device authorization was malformed or expired."
        }
    }
}

public actor LinuxDaemonCloudCredentialAuthority {
    public nonisolated let sessionEvents: AsyncStream<LinuxCloudAuthSessionEvent>

    private struct PendingSignIn {
        enum Phase {
            case authorizing
            case transitioningAccount
        }

        let operationID: String
        let flow: LinuxPKCELoopbackFlow
        let listener: LinuxOAuthLoopbackListener
        let expiresAt: Date
        var task: Task<Void, Never>?
        var phase: Phase
    }

    private struct CachedAppCheck {
        let token: String
        let expiresAt: Date
        let generation: UInt64
        let deviceID: String
    }

    private struct InstallationVerificationDescriptor {
        let deviceID: String
        let safetyFingerprint: String
    }

    private let configuration: LinuxCloudAuthConfiguration?
    private let tokenStore: LinuxAuthTokenStore
    private let identityStore: LinuxIrohHostIdentityStore
    private let http: LinuxCloudAuthHTTPClient
    private let now: @Sendable () -> Date
    private let approvalRetrySleeper: @Sendable (UInt64) async -> Void
    private let trustedDeviceAuthorizer: (any LinuxCloudTrustedDeviceActionAuthorizing)?
    private let hostname: String
    private let eventContinuation: AsyncStream<LinuxCloudAuthSessionEvent>.Continuation
    private var currentStatus: LinuxCloudAuthStatus
    private var pendingSignIn: PendingSignIn?
    private var firebaseSession: LinuxFirebaseSession?
    private var appCheck: CachedAppCheck?
    private var sessionGeneration: UInt64 = 1
    private var credentialTask: Task<LinuxIrohControllerCredentialContext, Error>?
    private var credentialTaskGeneration: UInt64?
    private var approvalRetryTask: Task<Void, Never>?
    private var lifecycleHandler: (@Sendable (LinuxCloudAuthSessionEvent) async -> Void)?
    private var teardownHandler: (@Sendable (LinuxIrohControllerCredentialContext?) async -> Void)?
    private var credentialAcquisitionBlocked = false
    private var signOutInProgress = false
    private var hasStoredSession: Bool
    private var storedIdentityUID: String?
    private var identityLabel: String?
    private var cloudDataControlStatus = LinuxCloudDataControlStatus.trustedDeviceBridgeUnavailable

    init(
        configuration: LinuxCloudAuthConfiguration?,
        custodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production(),
        httpTransport: @escaping LinuxCloudAuthHTTPTransport = LinuxCloudAuthHTTPClient.productionTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        approvalRetrySleeper: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: delay)
        },
        hostname: String = ProcessInfo.processInfo.hostName,
        trustedDeviceAuthorizer: (any LinuxCloudTrustedDeviceActionAuthorizing)? = nil
    ) {
        var continuation: AsyncStream<LinuxCloudAuthSessionEvent>.Continuation!
        sessionEvents = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        self.configuration = configuration
        let authTokenStore = LinuxAuthTokenStore(custodian: custodian)
        tokenStore = authTokenStore
        identityStore = LinuxIrohHostIdentityStore(custodian: custodian)
        let hosts = configuration.map {
            Set([$0.googleTokenEndpoint.host, $0.firebaseSignInEndpoint.host, $0.firebaseRefreshEndpoint.host, $0.functionsBaseURL.host].compactMap { $0 })
        } ?? []
        http = LinuxCloudAuthHTTPClient(allowedHosts: hosts, transport: httpTransport, now: now)
        self.now = now
        self.approvalRetrySleeper = approvalRetrySleeper
        self.trustedDeviceAuthorizer = trustedDeviceAuthorizer
        self.hostname = String(hostname.prefix(80))
        let restoredSession = try? Self.restoreStoredSession(using: authTokenStore)
        hasStoredSession = restoredSession != nil
        storedIdentityUID = restoredSession?.uid
        identityLabel = restoredSession?.identityLabel
        currentStatus = LinuxCloudAuthStatus(
            phase: configuration == nil ? .configurationRequired : .signedOut,
            hasStoredSession: hasStoredSession,
            reasonCode: configuration == nil ? "missing_cloud_configuration" : nil
        )
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LinuxDaemonCloudCredentialAuthority {
        LinuxDaemonCloudCredentialAuthority(
            configuration: .production(environment: environment),
            custodian: LinuxSecretStoreFactory.production(environment: environment)
        )
    }

    public func setLifecycleHandler(
        _ handler: (@Sendable (LinuxCloudAuthSessionEvent) async -> Void)?
    ) {
        lifecycleHandler = handler
    }

    public func setTeardownHandler(
        _ handler: (@Sendable (LinuxIrohControllerCredentialContext?) async -> Void)?
    ) {
        teardownHandler = handler
    }

    public func status() -> BurnBarLinuxAuthStatusResponse {
        var status = currentStatus
        if status.phase != .authorizing {
            status = LinuxCloudAuthStatus(
                phase: status.phase,
                operationID: status.operationID,
                operationExpiresAt: status.operationExpiresAt,
                hasStoredSession: hasStoredSession,
                reasonCode: status.reasonCode
            )
        }
        let state: BurnBarLinuxAuthState
        switch status.phase {
        case .signedOut: state = .signedOut
        case .authorizing: state = .authorizing
        case .awaitingDeviceApproval: state = .awaitingDeviceApproval
        case .ready: state = .active
        case .configurationRequired, .refreshing, .locked, .error: state = .unavailable
        }
        let signedIn = status.hasStoredSession && status.phase != .signedOut
            && status.phase != .configurationRequired
        let verification = signedIn ? installationVerificationDescriptor() : nil
        return BurnBarLinuxAuthStatusResponse(
            state: state,
            signedIn: signedIn,
            identityLabel: signedIn ? identityLabel : nil,
            trustClass: "linux-lower-trust",
            syncState: status.phase == .ready ? "cloud-ready" : "local-only",
            authorizationOperationID: status.operationID,
            authorizationExpiresAt: status.operationExpiresAt.map(Self.iso8601),
            deviceApprovalRequired: status.phase == .awaitingDeviceApproval,
            installationDeviceID: verification?.deviceID,
            installationSafetyFingerprint: verification?.safetyFingerprint,
            detail: status.reasonCode
        )
    }

    public func beginSignIn() throws -> BurnBarLinuxAuthBeginResponse {
        guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        guard signOutInProgress == false,
              credentialAcquisitionBlocked == false else {
            throw LinuxCloudAuthAuthorityError.sessionChanged
        }
        guard pendingSignIn == nil else { throw LinuxCloudAuthAuthorityError.authorizationInProgress }
        guard Self.validConfiguration(configuration) else { throw LinuxCloudAuthAuthorityError.configurationRequired }

        let operationID = UUID().uuidString.lowercased()
        let state = Self.randomBase64URL(byteCount: 32)
        let verifier = Self.randomBase64URL(byteCount: 64)
        let listener: LinuxOAuthLoopbackListener
        do {
            listener = try LinuxOAuthLoopbackListener(expectedState: state)
        } catch {
            throw LinuxCloudAuthAuthorityError.authorizationFailed
        }
        let flow = LinuxPKCELoopbackFlow(
            authBaseURL: configuration.authorizationEndpoint,
            clientID: configuration.googleOAuthClientID,
            callbackPort: listener.port,
            state: state,
            verifier: verifier,
            scopes: ["openid", "email", "profile"]
        )
        let expiresAt = now().addingTimeInterval(configuration.authorizationTimeout)
        pendingSignIn = PendingSignIn(
            operationID: operationID,
            flow: flow,
            listener: listener,
            expiresAt: expiresAt,
            task: nil,
            phase: .authorizing
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.completeSignIn(operationID: operationID)
        }
        pendingSignIn?.task = task
        currentStatus = LinuxCloudAuthStatus(
            phase: .authorizing,
            operationID: operationID,
            operationExpiresAt: expiresAt,
            hasStoredSession: hasStoredSession
        )
        return BurnBarLinuxAuthBeginResponse(
            operationID: operationID,
            authorizationURL: flow.authURL.absoluteString,
            expiresAt: Self.iso8601(expiresAt)
        )
    }

    public func cancelSignIn(operationID: String) throws {
        guard let pendingSignIn, pendingSignIn.operationID == operationID else {
            throw LinuxCloudAuthAuthorityError.operationMismatch
        }
        guard pendingSignIn.phase == .authorizing else {
            throw LinuxCloudAuthAuthorityError.sessionChanged
        }
        pendingSignIn.listener.cancel()
        pendingSignIn.task?.cancel()
        self.pendingSignIn = nil
        let retainedReadySession = validCachedContext() != nil
        currentStatus = LinuxCloudAuthStatus(
            phase: retainedReadySession ? .ready : .signedOut,
            hasStoredSession: hasStoredSession,
            reasonCode: "authorization_cancelled"
        )
    }

    public func signOut() async throws {
        guard signOutInProgress == false else { throw LinuxCloudAuthAuthorityError.sessionChanged }
        let teardownCredentials = validCachedContext()
        signOutInProgress = true
        credentialAcquisitionBlocked = true
        await performTeardown(credentials: teardownCredentials)
        invalidateInMemorySession()
        do {
            try tokenStore.clearRefreshToken()
        } catch LinuxSecretStoreError.missingSecret {
        } catch {
            invalidateInMemorySession()
            currentStatus = LinuxCloudAuthStatus(phase: .locked, hasStoredSession: true, reasonCode: "secure_store_unavailable")
            signOutInProgress = false
            credentialAcquisitionBlocked = false
            eventContinuation.yield(.invalidated)
            throw LinuxCloudAuthAuthorityError.secureStoreUnavailable
        }
        hasStoredSession = false
        invalidateInMemorySession()
        currentStatus = LinuxCloudAuthStatus(phase: configuration == nil ? .configurationRequired : .signedOut, hasStoredSession: false)
        signOutInProgress = false
        credentialAcquisitionBlocked = false
        eventContinuation.yield(.invalidated)
    }

    public func rotateInstallationIdentity() async throws {
        guard currentStatus.reasonCode == Self.reasonCode(.deviceRejected),
              hasStoredSession,
              signOutInProgress == false,
              pendingSignIn == nil else {
            throw LinuxCloudAuthAuthorityError.operationMismatch
        }
        let teardownCredentials = validCachedContext()
        credentialAcquisitionBlocked = true
        await performTeardown(credentials: teardownCredentials)
        invalidateInMemorySession()
        do {
            _ = try identityStore.rotate()
        } catch {
            credentialAcquisitionBlocked = false
            currentStatus = LinuxCloudAuthStatus(
                phase: .error,
                hasStoredSession: hasStoredSession,
                reasonCode: Self.reasonCode(.deviceRejected)
            )
            throw LinuxCloudAuthAuthorityError.installationIdentityUnavailable
        }
        credentialAcquisitionBlocked = false
        currentStatus = LinuxCloudAuthStatus(phase: .awaitingDeviceApproval, hasStoredSession: true)
        do {
            _ = try await credentialContext()
        } catch let error as LinuxCloudAuthAuthorityError {
            // The local key replacement is already committed. Return its
            // authoritative descriptor even when enrollment is pending or the
            // cloud is temporarily unavailable, and resume the bounded retry
            // loop instead of making the renderer retain the rejected key.
            if Self.shouldContinueApprovalRetry(after: error) {
                scheduleApprovalRetry()
            }
        }
    }

    public func credentialContext() async throws -> LinuxIrohControllerCredentialContext {
        guard configuration != nil else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        if credentialAcquisitionBlocked {
            if signOutInProgress { throw LinuxCloudAuthAuthorityError.sessionChanged }
            if currentStatus.phase == .locked { throw LinuxCloudAuthAuthorityError.secureStoreUnavailable }
            throw LinuxCloudAuthAuthorityError.notSignedIn
        }
        if let context = validCachedContext() { return context }
        if let credentialTask {
            let waiterGeneration = sessionGeneration
            do {
                let context = try await credentialTask.value
                guard credentialAcquisitionBlocked == false,
                      waiterGeneration == sessionGeneration,
                      context.sessionGeneration == waiterGeneration else {
                    throw LinuxCloudAuthAuthorityError.sessionChanged
                }
                return context
            } catch {
                guard credentialAcquisitionBlocked == false,
                      waiterGeneration == sessionGeneration else {
                    throw LinuxCloudAuthAuthorityError.sessionChanged
                }
                throw Self.map(error)
            }
        }
        let expectedGeneration = sessionGeneration
        currentStatus = LinuxCloudAuthStatus(phase: .refreshing, hasStoredSession: true)
        let task = Task { try await self.buildCredentialContext(expectedGeneration: expectedGeneration) }
        credentialTask = task
        credentialTaskGeneration = expectedGeneration
        do {
            let context = try await task.value
            guard credentialAcquisitionBlocked == false,
                  sessionGeneration == expectedGeneration,
                  context.sessionGeneration == expectedGeneration else {
                throw LinuxCloudAuthAuthorityError.sessionChanged
            }
            if credentialTaskGeneration == expectedGeneration {
                credentialTask = nil
                credentialTaskGeneration = nil
            }
            currentStatus = LinuxCloudAuthStatus(phase: .ready, hasStoredSession: true)
            eventContinuation.yield(.credentialsAvailable)
            await lifecycleHandler?(.credentialsAvailable)
            guard credentialAcquisitionBlocked == false,
                  sessionGeneration == expectedGeneration else {
                throw LinuxCloudAuthAuthorityError.sessionChanged
            }
            return context
        } catch {
            guard credentialAcquisitionBlocked == false,
                  sessionGeneration == expectedGeneration else {
                throw LinuxCloudAuthAuthorityError.sessionChanged
            }
            if credentialTaskGeneration == expectedGeneration {
                credentialTask = nil
                credentialTaskGeneration = nil
            }
            let mapped = Self.map(error)
            let phase: LinuxCloudAuthStatus.Phase = switch mapped {
            case .deviceApprovalRequired: .awaitingDeviceApproval
            case .secureStoreUnavailable: .locked
            case .reauthorizationRequired: .signedOut
            default: .error
            }
            currentStatus = LinuxCloudAuthStatus(
                phase: phase,
                hasStoredSession: hasStoredSession,
                reasonCode: Self.reasonCode(mapped)
            )
            if mapped == .deviceApprovalRequired { scheduleApprovalRetry() }
            throw mapped
        }
    }

    /// Forward a trusted-device-authorized data export through the daemon. The
    /// renderer never receives Firebase credentials or constructs action proofs;
    /// a future trusted-device bridge supplies the opaque proof envelope.
    public func exportUserData(
        domains: [String]? = nil,
        nonce: String,
        trustedDeviceId: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) async throws -> Data {
        guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        let context = try await credentialContext()
        let request = LinuxCloudDataExportRequest(
            domains: domains,
            nonce: nonce,
            trustedDeviceId: trustedDeviceId,
            actionProof: actionProof
        )
        do {
            return try await http.exportUserData(
                functionsBaseURL: configuration.functionsBaseURL,
                idToken: context.idToken,
                appCheckToken: context.appCheckToken,
                request: request
            )
        } catch let error as LinuxCloudAuthHTTPError {
            throw Self.map(error)
        }
    }

    /// Forward an explicitly confirmed, trusted-device-authorized account
    /// erasure. The confirmation phrase is checked before the irreversible
    /// callable is sent; server-side erasure remains the source of truth.
    public func deleteUserCloudData(
        confirmationToken: String,
        nonce: String,
        trustedDeviceId: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) async throws -> LinuxCloudDataDeletionResponse {
        guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        guard confirmationToken == LinuxCloudDataDeletionRequest.confirmationToken else {
            throw LinuxCloudAuthAuthorityError.operationMismatch
        }
        let context = try await credentialContext()
        let request = LinuxCloudDataDeletionRequest(
            confirmation: confirmationToken,
            nonce: nonce,
            trustedDeviceId: trustedDeviceId,
            actionProof: actionProof
        )
        do {
            return try await http.deleteUserCloudData(
                functionsBaseURL: configuration.functionsBaseURL,
                idToken: context.idToken,
                appCheckToken: context.appCheckToken,
                request: request
            )
        } catch let error as LinuxCloudAuthHTTPError {
            throw Self.map(error)
        }
    }

    /// Return redacted state for the daemon/UI status surface. Proof material,
    /// nonce values, and account identifiers are intentionally absent.
    public func cloudDataControlStatus() -> LinuxCloudDataControlStatus {
        cloudDataControlStatus
    }

    /// Start a daemon-owned export request. The trusted-device authorizer is
    /// the only component allowed to supply nonce-bound proof material; when it
    /// is not installed this method fails closed before touching credentials or
    /// the network.
    public func requestCloudDataExport(domains: [String]? = nil) async throws -> Data {
        guard let trustedDeviceAuthorizer else {
            cloudDataControlStatus = .trustedDeviceBridgeUnavailable
            throw LinuxCloudAuthAuthorityError.trustedDeviceBridgeUnavailable
        }
        let request = try beginCloudDataControl(
            operation: .export,
            actionKind: "data_export",
            subjectID: "all",
            domains: domains,
            requiresExplicitConfirmation: false
        )
        do {
            let authorization = try await trustedDeviceAuthorizer.authorize(request)
            try validateCloudDataControlAuthorization(authorization)
            cloudDataControlStatus = cloudDataControlStatusFor(
                request,
                phase: .executing,
                detail: "executing"
            )
            let context = try await credentialContext()
            guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
            let output = try await http.exportUserData(
                functionsBaseURL: configuration.functionsBaseURL,
                idToken: context.idToken,
                appCheckToken: context.appCheckToken,
                request: LinuxCloudDataExportRequest(
                    domains: domains,
                    nonce: authorization.nonce,
                    trustedDeviceId: authorization.trustedDeviceID,
                    actionProof: authorization.actionProof
                )
            )
            cloudDataControlStatus = cloudDataControlStatusFor(
                request,
                phase: .completed,
                detail: "completed"
            )
            return output
        } catch let error as LinuxCloudAuthAuthorityError {
            markCloudDataControlFailure(request, error: error)
            throw error
        } catch let error as LinuxCloudAuthHTTPError {
            let mapped = Self.map(error)
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        } catch is LinuxCloudTrustedDeviceActionAuthorizationError {
            let mapped = LinuxCloudAuthAuthorityError.trustedDeviceAuthorizationRejected
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        } catch {
            let mapped = LinuxCloudAuthAuthorityError.trustedDeviceAuthorizationRejected
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        }
    }

    /// Start a daemon-owned account-erasure request. The exact confirmation is
    /// checked before asking a trusted device for approval. This method does
    /// not persist the proof or perform local account deletion; the canonical
    /// callable remains authoritative for cloud cleanup and its retry summary.
    public func requestCloudDataDeletion(confirmationToken: String) async throws -> LinuxCloudDataDeletionResponse {
        guard confirmationToken == LinuxCloudDataDeletionRequest.confirmationToken else {
            throw LinuxCloudAuthAuthorityError.operationMismatch
        }
        guard let trustedDeviceAuthorizer else {
            cloudDataControlStatus = .trustedDeviceBridgeUnavailable
            throw LinuxCloudAuthAuthorityError.trustedDeviceBridgeUnavailable
        }
        let context = try await credentialContext()
        let request = try beginCloudDataControl(
            operation: .delete,
            actionKind: "user_cloud_data_delete",
            subjectID: context.uid,
            domains: nil,
            requiresExplicitConfirmation: true
        )
        do {
            let authorization = try await trustedDeviceAuthorizer.authorize(request)
            try validateCloudDataControlAuthorization(authorization)
            cloudDataControlStatus = cloudDataControlStatusFor(
                request,
                phase: .executing,
                detail: "executing"
            )
            guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
            let response = try await http.deleteUserCloudData(
                functionsBaseURL: configuration.functionsBaseURL,
                idToken: context.idToken,
                appCheckToken: context.appCheckToken,
                request: LinuxCloudDataDeletionRequest(
                    confirmation: confirmationToken,
                    nonce: authorization.nonce,
                    trustedDeviceId: authorization.trustedDeviceID,
                    actionProof: authorization.actionProof
                )
            )
            cloudDataControlStatus = cloudDataControlStatusFor(
                request,
                phase: .completed,
                detail: "completed"
            )
            return response
        } catch let error as LinuxCloudAuthAuthorityError {
            markCloudDataControlFailure(request, error: error)
            throw error
        } catch let error as LinuxCloudAuthHTTPError {
            let mapped = Self.map(error)
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        } catch is LinuxCloudTrustedDeviceActionAuthorizationError {
            let mapped = LinuxCloudAuthAuthorityError.trustedDeviceAuthorizationRejected
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        } catch {
            let mapped = LinuxCloudAuthAuthorityError.trustedDeviceAuthorizationRejected
            markCloudDataControlFailure(request, error: mapped)
            throw mapped
        }
    }

    private func beginCloudDataControl(
        operation: LinuxCloudDataControlOperation,
        actionKind: String,
        subjectID: String,
        domains: [String]?,
        requiresExplicitConfirmation: Bool
    ) throws -> LinuxCloudDataControlAuthorizationRequest {
        guard cloudDataControlStatus.phase != .awaitingTrustedDevice,
              cloudDataControlStatus.phase != .executing else {
            throw LinuxCloudAuthAuthorityError.dataControlInProgress
        }
        let requestedAt = now()
        let expiresAt = requestedAt.addingTimeInterval(5 * 60)
        let request = LinuxCloudDataControlAuthorizationRequest(
            requestID: UUID().uuidString.lowercased(),
            operation: operation,
            actionKind: actionKind,
            subjectID: subjectID,
            domains: domains,
            requiresExplicitConfirmation: requiresExplicitConfirmation,
            requestedAt: requestedAt,
            expiresAt: expiresAt
        )
        cloudDataControlStatus = cloudDataControlStatusFor(
            request,
            phase: .awaitingTrustedDevice,
            detail: "awaiting_trusted_device_approval"
        )
        return request
    }

    private func validateCloudDataControlAuthorization(
        _ authorization: LinuxCloudTrustedDeviceAuthorization
    ) throws {
        guard authorization.isWellFormed(now: now()) else {
            throw LinuxCloudAuthAuthorityError.dataControlAuthorizationInvalid
        }
    }

    private func cloudDataControlStatusFor(
        _ request: LinuxCloudDataControlAuthorizationRequest,
        phase: LinuxCloudDataControlPhase,
        detail: String
    ) -> LinuxCloudDataControlStatus {
        LinuxCloudDataControlStatus(
            phase: phase,
            operation: request.operation,
            requestID: request.requestID,
            requestedAt: Self.iso8601(request.requestedAt),
            expiresAt: Self.iso8601(request.expiresAt),
            detail: detail
        )
    }

    private func markCloudDataControlFailure(
        _ request: LinuxCloudDataControlAuthorizationRequest,
        error: LinuxCloudAuthAuthorityError
    ) {
        cloudDataControlStatus = cloudDataControlStatusFor(
            request,
            phase: .failed,
            detail: Self.reasonCode(error)
        )
    }

    private func installationVerificationDescriptor() -> InstallationVerificationDescriptor? {
        guard let identity = try? identityStore.loadOrCreate() else { return nil }
        let digest = PlatformCrypto.sha256Hex(identity.pairingKeypair.publicKeyRaw)
        let uppercaseDigest = digest.uppercased()
        let groups = stride(from: 0, to: uppercaseDigest.count, by: 4).map { offset in
            let start = uppercaseDigest.index(uppercaseDigest.startIndex, offsetBy: offset)
            let end = uppercaseDigest.index(
                start,
                offsetBy: min(4, uppercaseDigest.distance(from: start, to: uppercaseDigest.endIndex))
            )
            return String(uppercaseDigest[start..<end])
        }
        return InstallationVerificationDescriptor(
            deviceID: "linux_\(digest)",
            safetyFingerprint: groups.joined(separator: " ")
        )
    }

    private func completeSignIn(operationID: String) async {
        guard let pending = pendingSignIn, pending.operationID == operationID,
              let configuration else { return }
        do {
            let callback = try await pending.listener.waitForCallback(timeout: configuration.authorizationTimeout)
            try ensurePending(operationID)
            let code = try pending.flow.acceptCallback(callback)
            let redirectURI = "http://127.0.0.1:\(pending.flow.callbackPort)/callback"
            let google = try await http.exchangeGoogleAuthorizationCode(
                endpoint: configuration.googleTokenEndpoint,
                clientID: configuration.googleOAuthClientID,
                clientSecret: configuration.googleOAuthClientSecret,
                code: code,
                verifier: pending.flow.challenge.verifier,
                redirectURI: redirectURI
            )
            try ensurePending(operationID)
            let session = try await http.signInToFirebase(
                endpoint: configuration.firebaseSignInEndpoint,
                apiKey: configuration.firebaseAPIKey,
                googleIDToken: google.idToken,
                requestURI: redirectURI
            )
            try ensurePending(operationID)
            let transitionGeneration = sessionGeneration
            let teardownCredentials = validCachedContext()
            pendingSignIn?.phase = .transitioningAccount
            credentialAcquisitionBlocked = true
            await performTeardown(credentials: teardownCredentials)
            try Task.checkCancellation()
            try ensurePending(operationID)
            guard sessionGeneration == transitionGeneration,
                  signOutInProgress == false else {
                throw LinuxCloudAuthAuthorityError.sessionChanged
            }
            let retainedIdentityLabel = identityLabel
            let retainedIdentityUID = storedIdentityUID
            invalidateInMemorySession(cancelAuthorization: false)
            let label = Self.verifiedIdentityLabel(
                for: session,
                retaining: retainedIdentityLabel,
                retainedUID: retainedIdentityUID
            )
            do {
                try store(session: session, identityLabel: label)
            } catch {
                throw LinuxCloudAuthAuthorityError.secureStoreUnavailable
            }
            hasStoredSession = true
            firebaseSession = session
            storedIdentityUID = session.uid
            identityLabel = label
            pendingSignIn = nil
            currentStatus = LinuxCloudAuthStatus(phase: .awaitingDeviceApproval, hasStoredSession: true)
            credentialAcquisitionBlocked = false
            do {
                _ = try await credentialContext()
            } catch LinuxCloudAuthAuthorityError.deviceApprovalRequired {
            }
        } catch {
            guard pendingSignIn?.operationID == operationID else { return }
            pendingSignIn?.listener.cancel()
            pendingSignIn = nil
            credentialAcquisitionBlocked = false
            let mapped = Self.map(error)
            let retainedReadySession = validCachedContext() != nil
            let retryableWithoutSession = hasStoredSession == false
                && mapped != .secureStoreUnavailable
                && mapped != .configurationRequired
            let failurePhase: LinuxCloudAuthStatus.Phase
            if retainedReadySession {
                failurePhase = .ready
            } else if mapped == .secureStoreUnavailable {
                failurePhase = .locked
            } else if retryableWithoutSession {
                failurePhase = .signedOut
            } else {
                failurePhase = .error
            }
            currentStatus = LinuxCloudAuthStatus(
                phase: failurePhase,
                hasStoredSession: hasStoredSession,
                reasonCode: Self.reasonCode(mapped)
            )
        }
    }

    private func buildCredentialContext(expectedGeneration: UInt64) async throws -> LinuxIrohControllerCredentialContext {
        guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        var session = try await validFirebaseSession(expectedGeneration: expectedGeneration, forceRefresh: false)
        try ensureGeneration(expectedGeneration)
        let identity: LinuxIrohHostIdentity
        do {
            identity = try identityStore.loadOrCreate()
        } catch {
            throw LinuxCloudAuthAuthorityError.installationIdentityUnavailable
        }
        let deviceID = "linux_" + PlatformCrypto.sha256Hex(identity.pairingKeypair.publicKeyRaw)
        let issuedAtMillis = Int64(now().timeIntervalSince1970 * 1_000)
        let enrollment = Self.enrollmentPayload(
            uid: session.uid,
            deviceID: deviceID,
            appID: configuration.linuxAppCheckAppID,
            publicKeyBase64: identity.pairingKeypair.publicKeyBase64,
            issuedAtMillis: issuedAtMillis
        )
        let enrollmentSignature = try PlatformCrypto.ed25519Signature(
            message: enrollment,
            privateKey: identity.pairingKeypair.signingKey
        ).base64EncodedString()
        try await http.registerLinuxDevice(
            functionsBaseURL: configuration.functionsBaseURL,
            idToken: session.idToken,
            deviceID: deviceID,
            deviceName: hostname,
            appID: configuration.linuxAppCheckAppID,
            publicKeyBase64: identity.pairingKeypair.publicKeyBase64,
            issuedAtMillis: issuedAtMillis,
            signatureBase64: enrollmentSignature
        )
        try ensureGeneration(expectedGeneration)
        let challenge = try await http.issueLinuxChallenge(
            functionsBaseURL: configuration.functionsBaseURL,
            idToken: session.idToken,
            deviceID: deviceID,
            appID: configuration.linuxAppCheckAppID
        )
        try ensureGeneration(expectedGeneration)
        let nowMillis = Int64(now().timeIntervalSince1970 * 1_000)
        guard challenge.issuedAtMillis <= nowMillis + 60_000,
              challenge.expiresAtMillis > nowMillis else {
            throw LinuxCloudAuthAuthorityError.cloudUnavailable
        }
        let challengeSignature = try PlatformCrypto.ed25519Signature(
            message: challenge.canonicalPayload,
            privateKey: identity.pairingKeypair.signingKey
        ).base64EncodedString()
        let mint = try await http.mintLinuxAppCheck(
            functionsBaseURL: configuration.functionsBaseURL,
            idToken: session.idToken,
            deviceID: deviceID,
            appID: configuration.linuxAppCheckAppID,
            challengeID: challenge.challengeID,
            signatureBase64: challengeSignature
        )
        try ensureGeneration(expectedGeneration)
        try await http.bindAppCheck(
            functionsBaseURL: configuration.functionsBaseURL,
            idToken: session.idToken,
            appCheckToken: mint.token
        )
        try ensureGeneration(expectedGeneration)
        session = try await validFirebaseSession(expectedGeneration: expectedGeneration, forceRefresh: true)
        try ensureGeneration(expectedGeneration)
        guard let finalIdentity = try? identityStore.loadOrCreate(),
              "linux_" + PlatformCrypto.sha256Hex(finalIdentity.pairingKeypair.publicKeyRaw) == deviceID else {
            throw LinuxCloudAuthAuthorityError.sessionChanged
        }
        appCheck = CachedAppCheck(
            token: mint.token,
            expiresAt: mint.expiresAt,
            generation: expectedGeneration,
            deviceID: deviceID
        )
        firebaseSession = session
        return LinuxIrohControllerCredentialContext(
            uid: session.uid,
            sessionGeneration: expectedGeneration,
            idToken: session.idToken,
            appCheckToken: mint.token,
            deviceID: deviceID
        )
    }

    private func validFirebaseSession(expectedGeneration: UInt64, forceRefresh: Bool) async throws -> LinuxFirebaseSession {
        try ensureGeneration(expectedGeneration)
        if forceRefresh == false,
           let firebaseSession,
           firebaseSession.expiresAt.timeIntervalSince(now()) > 5 * 60 {
            return firebaseSession
        }
        let storedSession: LinuxStoredFirebaseSession
        do {
            storedSession = try Self.restoreStoredSession(using: tokenStore)
        } catch LinuxSecretStoreError.missingSecret {
            throw LinuxCloudAuthAuthorityError.notSignedIn
        } catch {
            throw LinuxCloudAuthAuthorityError.secureStoreUnavailable
        }
        guard let configuration else { throw LinuxCloudAuthAuthorityError.configurationRequired }
        let refreshed = try await http.refreshFirebaseSession(
            endpoint: configuration.firebaseRefreshEndpoint,
            apiKey: configuration.firebaseAPIKey,
            refreshToken: storedSession.refreshToken
        )
        try ensureGeneration(expectedGeneration)
        let expectedUID = firebaseSession?.uid ?? storedSession.uid ?? storedIdentityUID
        if let expectedUID, expectedUID != refreshed.uid {
            identityLabel = nil
            storedIdentityUID = nil
            throw LinuxCloudAuthAuthorityError.sessionChanged
        }
        let label = Self.verifiedIdentityLabel(
            for: refreshed,
            retaining: identityLabel ?? storedSession.identityLabel,
            retainedUID: expectedUID
        )
        do {
            try store(session: refreshed, identityLabel: label)
        } catch {
            throw LinuxCloudAuthAuthorityError.secureStoreUnavailable
        }
        firebaseSession = refreshed
        storedIdentityUID = refreshed.uid
        identityLabel = label
        return refreshed
    }

    private func store(session: LinuxFirebaseSession, identityLabel: String) throws {
        let storedSession = LinuxStoredFirebaseSession(
            schemaVersion: LinuxStoredFirebaseSession.currentSchemaVersion,
            refreshToken: session.refreshToken,
            uid: session.uid,
            identityLabel: identityLabel
        )
        _ = try tokenStore.custodian.storeHighValueSecret(
            storedSession.encoded(),
            id: "firebase-refresh-token",
            secretClass: .refreshToken
        )
    }

    private static func restoreStoredSession(
        using tokenStore: LinuxAuthTokenStore
    ) throws -> LinuxStoredFirebaseSession {
        let value = try tokenStore.custodian.requireHighValueSecret(
            id: "firebase-refresh-token",
            secretClass: .refreshToken
        ).secret
        return try LinuxStoredFirebaseSession.decode(value)
    }

    private static func verifiedIdentityLabel(
        for session: LinuxFirebaseSession,
        retaining retainedLabel: String?,
        retainedUID: String?
    ) -> String {
        if let claims = firebaseClaims(from: session.idToken),
           (claims["sub"] as? String ?? claims["user_id"] as? String) == session.uid {
            if claims["email_verified"] as? Bool == true,
               let email = normalizedIdentityLabel(claims["email"] as? String),
               email.contains("@"), email.contains(" ") == false {
                return email
            }
            if let name = normalizedIdentityLabel(claims["name"] as? String) {
                return name
            }
        }
        if retainedUID == session.uid,
           let retainedLabel = normalizedIdentityLabel(retainedLabel) {
            return retainedLabel
        }
        let fingerprint = PlatformCrypto.sha256Hex(Data(session.uid.utf8))
            .prefix(12)
            .uppercased()
        return "OpenBurnBar account \(fingerprint)"
    }

    private static func firebaseClaims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1].utf8.count <= 12_000 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64), data.count <= 8_192,
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else { return nil }
        return claims
    }

    private static func normalizedIdentityLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinuxStoredFirebaseSession.validIdentityLabel(normalized) ? normalized : nil
    }

    private func validCachedContext() -> LinuxIrohControllerCredentialContext? {
        guard let firebaseSession, let appCheck,
              appCheck.generation == sessionGeneration,
              firebaseSession.expiresAt.timeIntervalSince(now()) > 5 * 60,
              appCheck.expiresAt.timeIntervalSince(now()) > 5 * 60,
              let identity = try? identityStore.loadOrCreate() else { return nil }
        let deviceID = "linux_" + PlatformCrypto.sha256Hex(identity.pairingKeypair.publicKeyRaw)
        guard appCheck.deviceID == deviceID else { return nil }
        return LinuxIrohControllerCredentialContext(
            uid: firebaseSession.uid,
            sessionGeneration: sessionGeneration,
            idToken: firebaseSession.idToken,
            appCheckToken: appCheck.token,
            deviceID: deviceID
        )
    }

    private func ensurePending(_ operationID: String) throws {
        guard pendingSignIn?.operationID == operationID else { throw LinuxCloudAuthAuthorityError.operationMismatch }
    }

    private func ensureGeneration(_ expected: UInt64) throws {
        guard expected == sessionGeneration else { throw LinuxCloudAuthAuthorityError.sessionChanged }
    }

    private func invalidateInMemorySession(cancelAuthorization: Bool = true) {
        if cancelAuthorization {
            pendingSignIn?.listener.cancel()
            pendingSignIn?.task?.cancel()
            pendingSignIn = nil
        }
        sessionGeneration &+= 1
        firebaseSession = nil
        storedIdentityUID = nil
        identityLabel = nil
        appCheck = nil
        credentialTask?.cancel()
        credentialTask = nil
        credentialTaskGeneration = nil
        approvalRetryTask?.cancel()
        approvalRetryTask = nil
        eventContinuation.yield(.invalidated)
    }

    private func scheduleApprovalRetry() {
        guard approvalRetryTask == nil else { return }
        approvalRetryTask = Task { [weak self] in
            var retryIndex = 0
            while Task.isCancelled == false {
                await self?.approvalRetrySleeper(Self.approvalRetryDelayNanoseconds(at: retryIndex))
                guard Task.isCancelled == false, let self else { return }
                do {
                    _ = try await self.credentialContext()
                    await self.clearApprovalRetryTask()
                    return
                } catch let error as LinuxCloudAuthAuthorityError
                    where Self.shouldContinueApprovalRetry(after: error) {
                    await self.markApprovalRetryPending(after: error)
                    retryIndex += 1
                    continue
                } catch {
                    await self.clearApprovalRetryTask()
                    return
                }
            }
        }
    }

    nonisolated static func approvalRetryDelayNanoseconds(at index: Int) -> UInt64 {
        let delays: [UInt64] = [15, 30, 60, 120, 300]
        return delays[min(max(index, 0), delays.count - 1)] * 1_000_000_000
    }

    nonisolated static func shouldContinueApprovalRetry(
        after error: LinuxCloudAuthAuthorityError
    ) -> Bool {
        error == .deviceApprovalRequired || error == .cloudUnavailable
    }

    private func markApprovalRetryPending(after error: LinuxCloudAuthAuthorityError) {
        guard hasStoredSession, credentialAcquisitionBlocked == false else { return }
        currentStatus = LinuxCloudAuthStatus(
            phase: .awaitingDeviceApproval,
            hasStoredSession: true,
            reasonCode: error == .deviceApprovalRequired
                ? Self.reasonCode(error)
                : "device_approval_retrying"
        )
    }

    private func clearApprovalRetryTask() {
        approvalRetryTask = nil
    }

    private func performTeardown(
        credentials: LinuxIrohControllerCredentialContext?
    ) async {
        if let teardownHandler {
            await teardownHandler(credentials)
        } else {
            await lifecycleHandler?(.invalidated)
        }
    }

    static func enrollmentPayload(
        uid: String,
        deviceID: String,
        appID: String,
        publicKeyBase64: String,
        issuedAtMillis: Int64
    ) -> Data {
        Data("openburnbar.linux.appcheck.enroll.v1\n\(uid)\n\(deviceID)\n\(appID)\n\(publicKeyBase64)\n\(issuedAtMillis)".utf8)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func validConfiguration(_ configuration: LinuxCloudAuthConfiguration) -> Bool {
        guard LinuxCloudAuthConfiguration.validGoogleOAuthClientID(configuration.googleOAuthClientID),
              LinuxCloudAuthConfiguration.validFirebaseAPIKey(configuration.firebaseAPIKey),
              LinuxCloudAuthConfiguration.validLinuxAppCheckAppID(configuration.linuxAppCheckAppID),
              configuration.authorizationTimeout >= 30,
              configuration.authorizationTimeout <= 600 else { return false }
        let expectedHosts: [(URL, String)] = [
            (configuration.authorizationEndpoint, "accounts.google.com"),
            (configuration.googleTokenEndpoint, "oauth2.googleapis.com"),
            (configuration.firebaseSignInEndpoint, "identitytoolkit.googleapis.com"),
            (configuration.firebaseRefreshEndpoint, "securetoken.googleapis.com"),
            (configuration.functionsBaseURL, "us-central1-burnbar.cloudfunctions.net")
        ]
        return expectedHosts.allSatisfy { url, host in
            url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
                && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
        }
    }

    private static func map(_ error: Error) -> LinuxCloudAuthAuthorityError {
        if let error = error as? LinuxCloudAuthAuthorityError { return error }
        if let error = error as? LinuxCloudAuthHTTPError {
            if case let .rejected(stage, status, reason) = error,
               stage == "issue_linux_challenge",
               status == 403,
               reason == "linux_device_approval_required" {
                return .deviceApprovalRequired
            }
            if case let .rejected(stage, _, reason) = error,
               let reason,
               ["register_linux_device", "issue_linux_challenge", "mint_linux_app_check"].contains(stage),
               [
                   "linux_device_invalid_trust_state",
                   "linux_device_key_mismatch",
                   "linux_device_not_registered",
                   "linux_device_record_mismatch",
                   "linux_device_revoked"
               ].contains(reason) {
                return .deviceRejected
            }
            if case let .rejected(stage, _, reason) = error,
               ["register_linux_device", "issue_linux_challenge", "mint_linux_app_check"].contains(stage),
               reason == "linux_app_not_allowlisted" {
                return .appCheckConfigurationRejected
            }
            if case let .rejected(stage, status, _) = error,
               stage == "firebase_refresh",
               [400, 401].contains(status) {
                return .reauthorizationRequired
            }
            if case let .rejected(_, status, _) = error,
               status == 408 || status == 425 || status == 429 || status >= 500 {
                return .cloudUnavailable
            }
            switch error {
            case .transportFailure:
                return .cloudUnavailable
            case .invalidConfiguration:
                return .configurationRequired
            case .invalidRequest, .requestTooLarge, .responseTooLarge,
                 .rejected, .malformedResponse:
                return .cloudResponseInvalid
            }
        }
        if error is LinuxOAuthLoopbackError || error is LinuxAuthError { return .authorizationFailed }
        if error is LinuxSecretStoreError { return .secureStoreUnavailable }
        return .cloudUnavailable
    }

    private static func reasonCode(_ error: LinuxCloudAuthAuthorityError) -> String {
        switch error {
        case .configurationRequired: "missing_cloud_configuration"
        case .notSignedIn: "signed_out"
        case .authorizationInProgress: "authorization_in_progress"
        case .operationMismatch: "operation_mismatch"
        case .authorizationFailed: "authorization_failed"
        case .deviceApprovalRequired: "device_approval_required"
        case .deviceRejected: "device_rejected"
        case .appCheckConfigurationRejected: "app_check_configuration_rejected"
        case .reauthorizationRequired: "reauthorization_required"
        case .cloudResponseInvalid: "cloud_response_invalid"
        case .secureStoreUnavailable: "secure_store_unavailable"
        case .installationIdentityUnavailable: "installation_identity_unavailable"
        case .sessionChanged: "session_changed"
        case .cloudUnavailable: "cloud_unavailable"
        case .trustedDeviceBridgeUnavailable: "trusted_device_bridge_unavailable"
        case .dataControlInProgress: "data_control_in_progress"
        case .trustedDeviceAuthorizationRejected: "trusted_device_authorization_rejected"
        case .dataControlAuthorizationInvalid: "data_control_authorization_invalid"
        }
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
#else
/// Non-Linux placeholder keeps cross-platform daemon composition source-stable.
public actor LinuxDaemonCloudCredentialAuthority {}
#endif
