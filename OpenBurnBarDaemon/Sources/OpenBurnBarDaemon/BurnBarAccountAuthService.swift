import OpenBurnBarCore
import OpenBurnBarLinuxSecurity
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

public protocol BurnBarAccountServing: Sendable {
    func status() async -> BurnBarAccountStatusResponse
    func startDeviceAuthorization() async throws -> BurnBarAccountStatusResponse
    func pollDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse
    func cancelDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse
    func signOut() async throws -> BurnBarAccountStatusResponse
}

protocol BurnBarAccountTokenProviding: Sendable {
    func validIDToken() async throws -> String
}

protocol BurnBarAccountAppCheckContextProviding: Sendable {
    func validAppCheckContext() async throws -> BurnBarLinuxAppCheckAccountContext
    func appCheckIdentitySnapshot() async -> BurnBarLinuxAppCheckAccountIdentity?
}

protocol BurnBarDeviceAuthCloudClient: Sendable {
    func start(_ request: BurnBarDeviceAuthStartRequest) async throws -> BurnBarDeviceAuthStartResponse
    func poll(deviceCode: String, deviceSecret: String) async throws -> BurnBarDeviceAuthPollResponse
    func cancel(deviceCode: String, deviceSecret: String) async throws
}

protocol BurnBarFirebaseIdentityClient: Sendable {
    func signIn(customToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet
    func refresh(refreshToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet
    func profile(idToken: String, apiKey: String) async throws -> BurnBarFirebaseProfile
}

struct BurnBarDeviceAuthStartRequest: Encodable, Sendable {
    let purpose: String
    let clientType: String
    let displayName: String
    let deviceSecretHash: String
    let credentialDelivery: LinuxDesktopAuthCredentialDelivery
}

struct BurnBarDeviceAuthStartResponse: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let pollIntervalSeconds: Int
    let expiresInSeconds: Int
}

enum BurnBarDeviceAuthPollStatus: String, Decodable, Sendable {
    case pending = "authorization_pending"
    case approved
    case denied
    case expired
}

struct BurnBarDeviceAuthPollResponse: Sendable {
    let status: BurnBarDeviceAuthPollStatus
    let credentialEnvelope: LinuxDesktopAuthCredentialEnvelope?
}

struct BurnBarFirebaseTokenSet: Sendable {
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
    let localID: String?
    let email: String?
    let displayName: String?
    let photoURL: String?
}

struct BurnBarFirebaseProfile: Sendable {
    let uid: String
    let email: String?
    let displayName: String?
    let photoURL: String?
}

enum BurnBarAccountAuthError: Error, LocalizedError, Equatable, Sendable {
    case invalidFlow
    case secretStoreUnavailable
    case networkUnavailable
    case invalidResponse
    case reauthenticationRequired

    var errorDescription: String? {
        switch self {
        case .invalidFlow:
            return "The account authorization flow is no longer active."
        case .secretStoreUnavailable:
            return "An unlocked Secret Service or KWallet backend is required before signing in."
        case .networkUnavailable:
            return "OpenBurnBar could not reach the account service."
        case .invalidResponse:
            return "The account service returned an invalid response."
        case .reauthenticationRequired:
            return "Your OpenBurnBar session has expired. Sign in again."
        }
    }
}

actor BurnBarAccountAuthService: BurnBarAccountServing, BurnBarAccountTokenProviding,
    BurnBarAccountAppCheckContextProviding {
    private static let refreshLeadTime: TimeInterval = 5 * 60
    static let productionFirebaseAPIKey = "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4"

    private struct PendingFlow {
        let flowID: String
        let deviceCode: String
        let deviceSecret: String
        let deliveryKey: LinuxDesktopAuthDeliveryKey
        let session: BurnBarAccountDeviceAuthSession
        let expiresAt: Date
    }

    private struct DesktopCredentialPayload: Decodable, Sendable {
        let schemaVersion: Int
        let purpose: String
        let credentialKind: String
        let firebaseCustomToken: String
        let apiKey: String
        let projectId: String
    }

    private let deviceAuthClient: any BurnBarDeviceAuthCloudClient
    private let identityClient: any BurnBarFirebaseIdentityClient
    private let tokenStore: LinuxAuthTokenStore
    private let configuredFirebaseAPIKey: String?
    private let expectedFirebaseProjectID: String
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let makeDeviceSecret: @Sendable () -> String
    private let makeDeliveryKey: @Sendable () -> LinuxDesktopAuthDeliveryKey

    private var pendingFlow: PendingFlow?
    private var lastCancelledFlowID: String?
    private var cachedTokens: BurnBarFirebaseTokenSet?
    private var cachedProfile: BurnBarFirebaseProfile?
    private var firebaseAPIKey: String?
    private var credentialBackend: String?
    private var problem: BurnBarAccountProblem?
    private var didAttemptRestore = false
    private var refreshTask: Task<BurnBarFirebaseTokenSet, Error>?
    private var restoreTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0

    init(
        deviceAuthClient: any BurnBarDeviceAuthCloudClient,
        identityClient: any BurnBarFirebaseIdentityClient,
        tokenStore: LinuxAuthTokenStore,
        configuredFirebaseAPIKey: String? = nil,
        expectedFirebaseProjectID: String = "burnbar",
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        makeDeviceSecret: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        },
        makeDeliveryKey: @escaping @Sendable () -> LinuxDesktopAuthDeliveryKey = LinuxDesktopAuthDeliveryKey.init
    ) {
        self.deviceAuthClient = deviceAuthClient
        self.identityClient = identityClient
        self.tokenStore = tokenStore
        self.configuredFirebaseAPIKey = configuredFirebaseAPIKey?.trimmedNonEmpty
        self.firebaseAPIKey = configuredFirebaseAPIKey?.trimmedNonEmpty
        self.expectedFirebaseProjectID = expectedFirebaseProjectID
        self.now = now
        self.makeUUID = makeUUID
        self.makeDeviceSecret = makeDeviceSecret
        self.makeDeliveryKey = makeDeliveryKey
    }

    static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) -> BurnBarAccountAuthService {
        BurnBarAccountAuthService(
            deviceAuthClient: EnvironmentBurnBarDeviceAuthCloudClient(
                environment: environment,
                session: session
            ),
            identityClient: EnvironmentBurnBarFirebaseIdentityClient(
                environment: environment,
                session: session
            ),
            tokenStore: LinuxAuthTokenStore(custodian: LinuxSecretStoreFactory.production()),
            configuredFirebaseAPIKey: resolvedProductionFirebaseAPIKey(environment: environment),
            expectedFirebaseProjectID: environment["OPENBURNBAR_FIREBASE_PROJECT_ID"] ?? "burnbar"
        )
    }

    static func resolvedProductionFirebaseAPIKey(environment: [String: String]) -> String {
        guard let override = environment["OPENBURNBAR_FIREBASE_API_KEY"]?.trimmedNonEmpty,
              override.hasPrefix("AIza"),
              (32...128).contains(override.utf8.count),
              override.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return productionFirebaseAPIKey
        }
        return override
    }

    func status() async -> BurnBarAccountStatusResponse {
        await expirePendingFlowIfNeeded()
        if cachedTokens == nil {
            if let restoreTask {
                await restoreTask.value
            } else if didAttemptRestore == false {
                didAttemptRestore = true
                let generation = sessionGeneration
                let task = Task { await self.restorePersistedSession(generation: generation) }
                restoreTask = task
                await task.value
                if generation == sessionGeneration {
                    restoreTask = nil
                }
            }
        }
        return response()
    }

    func startDeviceAuthorization() async throws -> BurnBarAccountStatusResponse {
        guard cachedTokens == nil else { return response() }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        didAttemptRestore = true
        refreshTask?.cancel()
        refreshTask = nil
        restoreTask?.cancel()
        restoreTask = nil

        do {
            credentialBackend = try tokenStore.requireWritableBackend()
        } catch {
            problem = accountProblem(.secretStoreUnavailable)
            throw BurnBarAccountAuthError.secretStoreUnavailable
        }

        if let replacedFlow = pendingFlow {
            pendingFlow = nil
            cancelRemotely(replacedFlow)
        }

        let flowID = makeUUID().uuidString.uppercased()
        let deviceSecret = makeDeviceSecret()
        guard deviceSecret.count >= 32, deviceSecret.count <= 512 else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        let deliveryKey = makeDeliveryKey()
        let delivery: LinuxDesktopAuthCredentialDelivery
        do {
            delivery = try deliveryKey.credentialDelivery(flowBinding: flowID)
        } catch {
            throw BurnBarAccountAuthError.invalidResponse
        }

        let startRequest = BurnBarDeviceAuthStartRequest(
            purpose: "desktop_auth",
            clientType: "desktop_linux",
            displayName: "OpenBurnBar for Linux",
            deviceSecretHash: sha256Hex(deviceSecret),
            credentialDelivery: delivery
        )

        let started: BurnBarDeviceAuthStartResponse
        do {
            started = try await deviceAuthClient.start(startRequest)
        } catch let error as BurnBarAccountAuthError {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.invalidFlow }
            problem = accountProblem(for: error)
            throw error
        } catch {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.invalidFlow }
            problem = accountProblem(.networkUnavailable)
            throw BurnBarAccountAuthError.networkUnavailable
        }
        guard generation == sessionGeneration else {
            cancelRemotely(deviceCode: started.deviceCode, deviceSecret: deviceSecret)
            throw BurnBarAccountAuthError.invalidFlow
        }

        let expiresAt = now().addingTimeInterval(TimeInterval(started.expiresInSeconds))
        let session = BurnBarAccountDeviceAuthSession(
            flowID: flowID,
            userCode: started.userCode,
            verificationURL: started.verificationURL.absoluteString,
            expiresAt: iso(expiresAt),
            pollIntervalSeconds: started.pollIntervalSeconds
        )
        pendingFlow = PendingFlow(
            flowID: flowID,
            deviceCode: started.deviceCode,
            deviceSecret: deviceSecret,
            deliveryKey: deliveryKey,
            session: session,
            expiresAt: expiresAt
        )
        lastCancelledFlowID = nil
        problem = nil
        return response()
    }

    func pollDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse {
        guard let canonical = canonicalFlowID(flowID),
              let flow = pendingFlow,
              flow.flowID == canonical else {
            throw BurnBarAccountAuthError.invalidFlow
        }
        guard now() < flow.expiresAt else {
            sessionGeneration &+= 1
            pendingFlow = nil
            cancelRemotely(flow)
            problem = accountProblem(.authorizationExpired)
            return response()
        }

        let generation = sessionGeneration
        let pollResult: BurnBarDeviceAuthPollResponse
        do {
            pollResult = try await deviceAuthClient.poll(
                deviceCode: flow.deviceCode,
                deviceSecret: flow.deviceSecret
            )
        } catch let error as BurnBarAccountAuthError {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.invalidFlow }
            problem = accountProblem(for: error)
            throw error
        } catch {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.invalidFlow }
            problem = accountProblem(.networkUnavailable)
            throw BurnBarAccountAuthError.networkUnavailable
        }
        guard generation == sessionGeneration else { throw BurnBarAccountAuthError.invalidFlow }

        switch pollResult.status {
        case .pending:
            problem = nil
            return response()
        case .denied, .expired:
            sessionGeneration &+= 1
            pendingFlow = nil
            problem = accountProblem(.authorizationExpired)
            return response()
        case .approved:
            // The server consumes an approved poll session. Drop verifier material
            // before any downstream token exchange so it cannot linger or be retried.
            sessionGeneration &+= 1
            let authorizationGeneration = sessionGeneration
            pendingFlow = nil
            guard let envelope = pollResult.credentialEnvelope else {
                problem = accountProblem(.reauthenticationRequired)
                return response()
            }
            do {
                return try await completeAuthorization(
                    envelope: envelope,
                    flow: flow,
                    generation: authorizationGeneration
                )
            } catch let error as BurnBarAccountAuthError {
                guard authorizationGeneration == sessionGeneration else { return response() }
                problem = accountProblem(for: error)
                return response()
            } catch {
                guard authorizationGeneration == sessionGeneration else { return response() }
                problem = accountProblem(.reauthenticationRequired)
                return response()
            }
        }
    }

    func cancelDeviceAuthorization(flowID: String) async throws -> BurnBarAccountStatusResponse {
        guard let canonical = canonicalFlowID(flowID) else {
            throw BurnBarAccountAuthError.invalidFlow
        }
        if let flow = pendingFlow {
            guard flow.flowID == canonical else { throw BurnBarAccountAuthError.invalidFlow }
            sessionGeneration &+= 1
            pendingFlow = nil
            lastCancelledFlowID = canonical
            cancelRemotely(flow)
        } else if lastCancelledFlowID != canonical {
            throw BurnBarAccountAuthError.invalidFlow
        }
        problem = nil
        return response()
    }

    func signOut() async throws -> BurnBarAccountStatusResponse {
        // Deleting the durable credential is the commit point for sign-out.
        // Keep the in-memory session intact when the keyring cannot delete it,
        // so the UI and the next daemon process cannot disagree about identity.
        do {
            try tokenStore.clearRefreshToken()
        } catch {
            problem = accountProblem(.secretStoreUnavailable)
            throw BurnBarAccountAuthError.secretStoreUnavailable
        }

        // Local teardown is authoritative. Discarding the verifier and delivery
        // key makes a pending server session unusable until its short TTL expires.
        pendingFlow = nil
        lastCancelledFlowID = nil
        cachedTokens = nil
        cachedProfile = nil
        firebaseAPIKey = configuredFirebaseAPIKey
        sessionGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        didAttemptRestore = true
        problem = nil
        credentialBackend = try? tokenStore.requireWritableBackend()
        return response()
    }

    func validIDToken() async throws -> String {
        if let tokens = cachedTokens,
           tokens.expiresAt.timeIntervalSince(now()) > Self.refreshLeadTime {
            return tokens.idToken
        }
        return try await refreshIDToken().idToken
    }

    func validAppCheckContext() async throws -> BurnBarLinuxAppCheckAccountContext {
        let idToken = try await validIDToken()
        guard let uid = (cachedProfile?.uid ?? cachedTokens?.localID)?.trimmedNonEmpty else {
            throw BurnBarAccountAuthError.reauthenticationRequired
        }
        return BurnBarLinuxAppCheckAccountContext(
            uid: uid,
            sessionGeneration: sessionGeneration,
            idToken: idToken
        )
    }

    func appCheckIdentitySnapshot() -> BurnBarLinuxAppCheckAccountIdentity? {
        guard cachedTokens != nil,
              let uid = (cachedProfile?.uid ?? cachedTokens?.localID)?.trimmedNonEmpty else {
            return nil
        }
        return BurnBarLinuxAppCheckAccountIdentity(uid: uid, sessionGeneration: sessionGeneration)
    }

    private func completeAuthorization(
        envelope: LinuxDesktopAuthCredentialEnvelope,
        flow: PendingFlow,
        generation: UInt64
    ) async throws -> BurnBarAccountStatusResponse {
        let opened: Data
        do {
            opened = try flow.deliveryKey.open(envelope, flowBinding: flow.flowID)
        } catch {
            problem = accountProblem(.reauthenticationRequired)
            throw BurnBarAccountAuthError.invalidResponse
        }

        let payload: DesktopCredentialPayload
        do {
            payload = try JSONDecoder().decode(DesktopCredentialPayload.self, from: opened)
        } catch {
            throw BurnBarAccountAuthError.invalidResponse
        }
        guard payload.schemaVersion == 1,
              payload.purpose == "desktop_auth",
              payload.credentialKind == "firebase_custom_token",
              let customToken = payload.firebaseCustomToken.trimmedNonEmpty,
              let apiKey = payload.apiKey.trimmedNonEmpty,
              customToken.utf8.count <= 16_384,
              apiKey.utf8.count <= 512,
              payload.projectId == expectedFirebaseProjectID else {
            throw BurnBarAccountAuthError.invalidResponse
        }

        let tokens: BurnBarFirebaseTokenSet
        do {
            tokens = try await identityClient.signIn(customToken: customToken, apiKey: apiKey)
        } catch let error as BurnBarAccountAuthError {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.reauthenticationRequired }
            problem = accountProblem(for: error)
            throw error
        } catch {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.reauthenticationRequired }
            problem = accountProblem(.networkUnavailable)
            throw BurnBarAccountAuthError.networkUnavailable
        }
        guard generation == sessionGeneration else {
            throw BurnBarAccountAuthError.reauthenticationRequired
        }

        let metadata: LinuxSecretMetadata
        do {
            metadata = try tokenStore.storeRefreshToken(tokens.refreshToken)
        } catch {
            problem = accountProblem(.secretStoreUnavailable)
            throw BurnBarAccountAuthError.secretStoreUnavailable
        }

        refreshTask?.cancel()
        refreshTask = nil
        firebaseAPIKey = apiKey
        credentialBackend = metadata.backend
        cachedTokens = tokens
        cachedProfile = nil
        didAttemptRestore = true

        do {
            let profile = try await identityClient.profile(idToken: tokens.idToken, apiKey: apiKey)
            guard generation == sessionGeneration else {
                throw BurnBarAccountAuthError.reauthenticationRequired
            }
            cachedProfile = profile
        } catch let error as BurnBarAccountAuthError {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.reauthenticationRequired }
            problem = accountProblem(for: error)
            return response()
        } catch {
            guard generation == sessionGeneration else { throw BurnBarAccountAuthError.reauthenticationRequired }
            problem = accountProblem(.networkUnavailable)
            return response()
        }
        problem = nil
        return response()
    }

    private func restorePersistedSession(generation: UInt64) async {
        guard generation == sessionGeneration else { return }
        guard let apiKey = firebaseAPIKey else {
            if let record = try? tokenStore.loadRefreshToken() {
                credentialBackend = record.metadata.backend
                problem = accountProblem(.reauthenticationRequired)
            }
            return
        }
        do {
            _ = try await refreshIDToken()
            guard generation == sessionGeneration else { return }
            if let token = cachedTokens?.idToken {
                let profile = try await identityClient.profile(idToken: token, apiKey: apiKey)
                guard generation == sessionGeneration else { return }
                cachedProfile = profile
            }
            problem = nil
        } catch let error as BurnBarAccountAuthError {
            if error != .reauthenticationRequired {
                problem = accountProblem(for: error)
            }
        } catch {
            problem = accountProblem(.networkUnavailable)
        }
    }

    private func refreshIDToken() async throws -> BurnBarFirebaseTokenSet {
        guard let apiKey = firebaseAPIKey else {
            throw BurnBarAccountAuthError.reauthenticationRequired
        }
        let generation = sessionGeneration

        let refreshToken: String
        do {
            let record = try tokenStore.loadRefreshToken()
            refreshToken = record.secret
            credentialBackend = record.metadata.backend
        } catch let error as LinuxSecretStoreError {
            switch error {
            case .missingSecret:
                throw BurnBarAccountAuthError.reauthenticationRequired
            default:
                throw BurnBarAccountAuthError.secretStoreUnavailable
            }
        } catch {
            throw BurnBarAccountAuthError.secretStoreUnavailable
        }

        let task: Task<BurnBarFirebaseTokenSet, Error>
        if let existing = refreshTask {
            task = existing
        } else {
            let identityClient = self.identityClient
            task = Task<BurnBarFirebaseTokenSet, Error> {
                try await identityClient.refresh(refreshToken: refreshToken, apiKey: apiKey)
            }
            refreshTask = task
        }

        let refreshed: BurnBarFirebaseTokenSet
        do {
            refreshed = try await task.value
        } catch let error as BurnBarAccountAuthError {
            guard generation == sessionGeneration else {
                throw BurnBarAccountAuthError.reauthenticationRequired
            }
            refreshTask = nil
            if error == .reauthenticationRequired {
                cachedTokens = nil
                cachedProfile = nil
                _ = try? tokenStore.clearRefreshToken()
            }
            problem = accountProblem(for: error)
            throw error
        } catch is LinuxSecretStoreError {
            guard generation == sessionGeneration else {
                throw BurnBarAccountAuthError.reauthenticationRequired
            }
            refreshTask = nil
            problem = accountProblem(.secretStoreUnavailable)
            throw BurnBarAccountAuthError.secretStoreUnavailable
        } catch {
            guard generation == sessionGeneration else {
                throw BurnBarAccountAuthError.reauthenticationRequired
            }
            refreshTask = nil
            problem = accountProblem(.networkUnavailable)
            throw BurnBarAccountAuthError.networkUnavailable
        }

        guard generation == sessionGeneration else {
            throw BurnBarAccountAuthError.reauthenticationRequired
        }
        if let cachedTokens, cachedTokens.idToken == refreshed.idToken {
            refreshTask = nil
            return cachedTokens
        }
        do {
            _ = try tokenStore.storeRefreshToken(refreshed.refreshToken)
        } catch {
            refreshTask = nil
            problem = accountProblem(.secretStoreUnavailable)
            throw BurnBarAccountAuthError.secretStoreUnavailable
        }
        refreshTask = nil
        cachedTokens = refreshed
        problem = nil
        return refreshed
    }

    private func response() -> BurnBarAccountStatusResponse {
        let state: BurnBarAccountState
        if cachedTokens != nil {
            state = .signedIn
        } else if pendingFlow != nil {
            state = .authorizationPending
        } else {
            state = .signedOut
        }
        return BurnBarAccountStatusResponse(account: BurnBarAccountSnapshot(
            state: state,
            uid: cachedProfile?.uid ?? cachedTokens?.localID,
            email: cachedProfile?.email ?? cachedTokens?.email,
            displayName: cachedProfile?.displayName ?? cachedTokens?.displayName,
            photoURL: cachedProfile?.photoURL ?? cachedTokens?.photoURL,
            trustClass: "linux_lower_trust",
            syncState: "local_only",
            credentialBackend: credentialBackend,
            session: pendingFlow?.session,
            problem: problem,
            updatedAt: iso(now())
        ))
    }

    private func expirePendingFlowIfNeeded() async {
        guard let flow = pendingFlow, now() >= flow.expiresAt else { return }
        sessionGeneration &+= 1
        pendingFlow = nil
        cancelRemotely(flow)
        problem = accountProblem(.authorizationExpired)
    }

    private func cancelRemotely(_ flow: PendingFlow) {
        cancelRemotely(deviceCode: flow.deviceCode, deviceSecret: flow.deviceSecret)
    }

    private func cancelRemotely(deviceCode: String, deviceSecret: String) {
        let client = deviceAuthClient
        Task {
            try? await client.cancel(
                deviceCode: deviceCode,
                deviceSecret: deviceSecret
            )
        }
    }

    private func canonicalFlowID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.uppercased()
    }

    private func sha256Hex(_ value: String) -> String {
        let challenge = LinuxPKCEChallenge(verifier: value).challenge
        var base64 = challenge.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let digest = Data(base64Encoded: base64) else { return "" }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func accountProblem(for error: BurnBarAccountAuthError) -> BurnBarAccountProblem {
        switch error {
        case .secretStoreUnavailable:
            return accountProblem(.secretStoreUnavailable)
        case .networkUnavailable:
            return accountProblem(.networkUnavailable)
        case .reauthenticationRequired:
            return accountProblem(.reauthenticationRequired)
        case .invalidFlow, .invalidResponse:
            return accountProblem(.reauthenticationRequired)
        }
    }

    private func accountProblem(_ code: BurnBarAccountProblemCode) -> BurnBarAccountProblem {
        let message: String
        let recoverable: Bool
        switch code {
        case .secretStoreUnavailable:
            message = "Unlock Secret Service or KWallet, then retry."
            recoverable = true
        case .networkUnavailable:
            message = "The account service is temporarily unavailable."
            recoverable = true
        case .reauthenticationRequired:
            message = "Sign in again to reconnect your OpenBurnBar account."
            recoverable = true
        case .authorizationExpired:
            message = "The authorization request expired or was denied."
            recoverable = true
        }
        return BurnBarAccountProblem(code: code, message: message, recoverable: recoverable)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
