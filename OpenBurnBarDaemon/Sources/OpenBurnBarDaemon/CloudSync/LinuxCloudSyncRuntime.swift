import Foundation

/// Identity and key material resolved inside the daemon immediately before an
/// operation. Implementations obtain the UID from the credential authority and
/// the 32-byte vault key from an approved Linux SecretStore backend.
public typealias LinuxCloudSyncIdentityProvider = @Sendable () async throws -> String
public typealias LinuxCloudSyncVaultKeyProvider = @Sendable () async throws -> Data

public struct BurnBarLinuxCloudSyncPolicyUpdateRequest: Codable, Hashable, Sendable {
    public let enabledDomains: [String]
    public let remoteAccessEnabled: Bool

    public init(enabledDomains: [String], remoteAccessEnabled: Bool) {
        self.enabledDomains = enabledDomains
        self.remoteAccessEnabled = remoteAccessEnabled
    }
}

public struct BurnBarLinuxCloudSyncRunRequest: Codable, Hashable, Sendable {
    public let force: Bool

    public init(force: Bool = false) { self.force = force }
}

public struct BurnBarLinuxCloudSyncStatusResponse: Codable, Hashable, Sendable {
    public let phase: String
    public let pendingMutationCount: Int
    public let consecutiveFailures: Int
    public let retryAtMillis: Int64?
    public let lastSuccessfulSyncAtMillis: Int64?
    public let enabledDomains: [String]
    public let remoteAccessEnabled: Bool
    public let vaultKeyAvailable: Bool

    public init(
        phase: String,
        pendingMutationCount: Int,
        consecutiveFailures: Int,
        retryAtMillis: Int64?,
        lastSuccessfulSyncAtMillis: Int64?,
        enabledDomains: [String],
        remoteAccessEnabled: Bool,
        vaultKeyAvailable: Bool
    ) {
        self.phase = phase
        self.pendingMutationCount = pendingMutationCount
        self.consecutiveFailures = consecutiveFailures
        self.retryAtMillis = retryAtMillis
        self.lastSuccessfulSyncAtMillis = lastSuccessfulSyncAtMillis
        self.enabledDomains = enabledDomains
        self.remoteAccessEnabled = remoteAccessEnabled
        self.vaultKeyAvailable = vaultKeyAvailable
    }
}

public struct BurnBarLinuxCloudSyncRunResponse: Codable, Hashable, Sendable {
    public let pushedCount: Int
    public let appliedRemoteCount: Int
    public let retainedLocalConflictCount: Int
    public let status: BurnBarLinuxCloudSyncStatusResponse

    public init(
        pushedCount: Int,
        appliedRemoteCount: Int,
        retainedLocalConflictCount: Int,
        status: BurnBarLinuxCloudSyncStatusResponse
    ) {
        self.pushedCount = pushedCount
        self.appliedRemoteCount = appliedRemoteCount
        self.retainedLocalConflictCount = retainedLocalConflictCount
        self.status = status
    }
}

/// Runtime composition boundary used by daemon RPC. The renderer can change
/// consent and request a cycle, but never receives account IDs, vault keys,
/// Firebase tokens, cursors, ciphertext, or plaintext replicas.
public actor LinuxCloudSyncRuntime {
    public static let defaultBackgroundIntervalMillis: Int64 = 5 * 60 * 1_000

    private let engine: LinuxCloudReplicaEngine
    private let identityProvider: LinuxCloudSyncIdentityProvider
    private let vaultKeyProvider: LinuxCloudSyncVaultKeyProvider
    private let backgroundIntervalMillis: Int64
    private var backgroundTask: Task<Void, Never>?

    public init(
        engine: LinuxCloudReplicaEngine,
        identityProvider: @escaping LinuxCloudSyncIdentityProvider,
        vaultKeyProvider: @escaping LinuxCloudSyncVaultKeyProvider,
        backgroundIntervalMillis: Int64 = 5 * 60 * 1_000
    ) {
        precondition(backgroundIntervalMillis > 0)
        self.engine = engine
        self.identityProvider = identityProvider
        self.vaultKeyProvider = vaultKeyProvider
        self.backgroundIntervalMillis = backgroundIntervalMillis
        self.backgroundTask = nil
    }

    /// Starts the daemon-owned periodic sync loop. Consent, authentication,
    /// and vault-key checks remain inside `run`; a locked or signed-out daemon
    /// therefore stays available without exposing credentials to the renderer.
    public func startBackgroundLoop() {
        guard backgroundTask == nil else { return }
        let intervalNanos = UInt64(backgroundIntervalMillis) * 1_000_000
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                _ = try? await self?.run(force: false)
            }
        }
    }

    /// Stops and joins the periodic loop during daemon shutdown. Calling this
    /// more than once is safe and leaves manual RPC runs unaffected.
    public func stopBackgroundLoop() async {
        let task = backgroundTask
        backgroundTask = nil
        task?.cancel()
        _ = await task?.result
    }

    public var backgroundLoopIsRunning: Bool {
        backgroundTask != nil
    }

    public func status() async throws -> BurnBarLinuxCloudSyncStatusResponse {
        let uid = try await identityProvider()
        return try await response(from: engine.status(uid: uid))
    }

    public func updatePolicy(_ request: BurnBarLinuxCloudSyncPolicyUpdateRequest) async throws
        -> BurnBarLinuxCloudSyncStatusResponse {
        let uid = try await identityProvider()
        let domains = try Set(request.enabledDomains.map { raw -> LinuxCloudReplicaEngine.Domain in
            guard let domain = LinuxCloudReplicaEngine.Domain(rawValue: raw),
                  LinuxCloudReplicaEngine.Domain.supported.contains(domain) else {
                throw LinuxCloudReplicaEngine.EngineError.invalidIdentifier
            }
            return domain
        })
        try await engine.setConsentPolicy(
            .init(enabledDomains: domains, remoteAccessEnabled: request.remoteAccessEnabled),
            uid: uid
        )
        return try await response(from: engine.status(uid: uid))
    }

    public func run(force: Bool) async throws -> BurnBarLinuxCloudSyncRunResponse {
        let uid = try await identityProvider()
        let vaultKey = try await vaultKeyProvider()
        let result = try await engine.syncOnce(uid: uid, vaultKey: vaultKey, force: force)
        let status = try await response(from: engine.status(uid: uid), vaultKeyAvailable: true)
        return BurnBarLinuxCloudSyncRunResponse(
            pushedCount: result.pushedCount,
            appliedRemoteCount: result.appliedRemoteCount,
            retainedLocalConflictCount: result.retainedLocalConflictCount,
            status: status
        )
    }

    private func response(
        from status: LinuxCloudReplicaEngine.Status,
        vaultKeyAvailable knownVaultKeyAvailability: Bool? = nil
    ) async -> BurnBarLinuxCloudSyncStatusResponse {
        let vaultKeyAvailable: Bool
        if let knownVaultKeyAvailability {
            vaultKeyAvailable = knownVaultKeyAvailability
        } else {
            vaultKeyAvailable = ((try? await vaultKeyProvider())?.count == 32)
        }
        return BurnBarLinuxCloudSyncStatusResponse(
            phase: vaultKeyAvailable ? status.phase.rawValue : "locked",
            pendingMutationCount: status.pendingMutationCount,
            consecutiveFailures: status.consecutiveFailures,
            retryAtMillis: status.retryAtMillis,
            lastSuccessfulSyncAtMillis: status.lastSuccessfulSyncAtMillis,
            enabledDomains: status.enabledDomains.map(\.rawValue).sorted(),
            remoteAccessEnabled: status.remoteAccessEnabled,
            vaultKeyAvailable: vaultKeyAvailable
        )
    }
}
