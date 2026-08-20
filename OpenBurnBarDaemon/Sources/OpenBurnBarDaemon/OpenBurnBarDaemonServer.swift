import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
public typealias LinuxComputerUseOwnerAuthorizer = @Sendable (
    _ peerProcessID: Int32,
    _ operationID: String,
    _ reason: String
) async throws -> Void

/// Resolves phone-pairing authority from daemon-owned state for one exact run.
/// The socket client cannot supply peer, device, connection, or grant scope.
public typealias ComputerUseSessionGrantMetadataResolver = @Sendable (
    _ requirement: BurnBarComputerUseRunRequirement,
    _ request: ComputerUseSessionStartRequest
) async throws -> ComputerUseSessionGrantBroker.AcquisitionMetadata

/// Confirms that the daemon can resolve a currently trusted paired controller
/// before the desktop advertises the Browser Computer Use flow as available.
public typealias ComputerUseSessionGrantReadinessProvider = @Sendable () async -> Bool

enum ComputerUseTransportIngressError: Error, Equatable, Sendable {
    case rejected
}

enum ComputerUseIngressProvenance: Equatable, Sendable {
    case authenticatedIrohTransport(peerNodeID: String, routeGeneration: Int64)
    case authenticatedLocalRPC
}

public actor BurnBarDaemonServer {
    private static let maxRequestBytes = 64 * 1024

    public let configuration: BurnBarDaemonConfiguration

    let logger: BurnBarDaemonLogger
    /// Round-4 perf sweep: bounded concurrency gate for the accept loop.
    /// Caps the number of simultaneously in-flight connection handlers to
    /// prevent FD/memory exhaustion under client bursts. See
    /// `BurnBarConnectionGate` for the contract.
    let connectionGate: BurnBarConnectionGate
    /// RR-3: first-party code-signature gate for accepted control-socket peers.
    /// Enforced in production (wired by `OpenBurnBarDaemonMain`); `.disabled` for
    /// in-process tests and unsigned developer builds.
    let peerAuthenticator: BurnBarDaemonPeerAuthenticator
    /// T-DMN-01: per-operation capability attenuation. Every authenticated peer is
    /// scoped to this set of capability groups; any RPC whose group is outside the
    /// set is refused (fail closed) before dispatch, so a compromised first-party
    /// peer cannot exercise full RPC/HID agency from a code-sign identity alone.
    /// Defaults to `.full` for backward compatibility with the trusted controller
    /// app; less-trusted session types pass an attenuated profile.
    let capabilityProfile: BurnBarPeerCapabilityProfile
    /// T-DMN-04: independent daemon-side re-verification of the single-use,
    /// op-hash-bound Ed25519 local-auth proof that authorizes a high-risk
    /// computer-use RPC (`computerUseSessionStart` / `computerUseInvoke`). When
    /// non-`nil` the daemon FAILS CLOSED on those methods unless the request
    /// carries a proof that verifies against the PINNED phone key — so the proof
    /// binding survives a compromise of the first-party app that forwarded the
    /// request. `nil` (the default) preserves existing behavior for in-process
    /// tests and unsigned developer builds; production wires it enforcing on the
    /// same flag as the peer-codesig gate.
    let localAuthProofVerifier: DaemonLocalAuthProofVerifier?
    /// T-DMN-04: daemon-side store for pinned phone-control verifying keys. The
    /// first-party Mac app provisions this store via `phoneControlPinProvision` so
    /// the daemon can verify local-auth proofs independently of the app.
    let phoneControlPinStore: DaemonPhoneKeyPinStore?
    let computerUseApprovalAuthorityVerifier: DaemonComputerUseApprovalAuthorityVerifier?
    let computerUsePanicAuthorityVerifier: DaemonComputerUsePanicAuthorityVerifier?
    let computerUseSessionGrantBroker: ComputerUseSessionGrantBroker?
    let computerUseSessionGrantMetadataResolver: ComputerUseSessionGrantMetadataResolver?
    let computerUseSessionGrantReadinessProvider: ComputerUseSessionGrantReadinessProvider?
    let fleetService: BurnBarFleetService
    let flameService: BurnBarFlameService
    #if os(Linux)
    let linuxComputerUseOwnerAuthorizer: LinuxComputerUseOwnerAuthorizer
    let linuxCloudCredentialAuthority: LinuxDaemonCloudCredentialAuthority?
    /// Optional companion-device bridge for trusted-device list/approve/revoke.
    /// Production composition leaves this nil until the authenticated callable
    /// and Iroh/mobile transport are available; RPCs then fail closed.
    let linuxTrustedDeviceManager: (any LinuxTrustedDeviceManaging)?
    let linuxCloudSyncRuntime: LinuxCloudSyncRuntime?
    let linuxIrohControllerRuntime: LinuxIrohControllerRuntime?
    let linuxIrohControllerUnavailableStatus: LinuxIrohControllerRuntime.RuntimeStatus?
    #endif
    let linuxOnboardingService: BurnBarLinuxOnboardingService
    let subscriptionService: BurnBarSubscriptionService
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    let localUsageIngestionService: BurnBarLocalUsageIngestionService?
    let proxyRouteLogStore: BurnBarProxyRouteLogStore
    let quotaSignalStore: BurnBarQuotaSignalStore
    #if os(Linux)
    let linuxQuotaRefreshService: BurnBarLinuxQuotaRefreshService
    #endif
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
    let toolingProxy: BurnBarToolingProxyService
    let computerUseService: ComputerUseService
    let computerUseAuthorizationRegistry: ComputerUseAuthorizationRegistry
    #if os(Linux)
    let mediaService: MercuryLinuxMediaSessionController
    let linuxPrivacyService: BurnBarLinuxPrivacyService
    #endif
    let missionControlService: any BurnBarMissionControlServing
    let membershipService: any BurnBarMembershipServing
    var chatThreadService: (any BurnBarChatThreadServing)?
    var indexedSearch: BurnBarIndexedSearchService?
    /// The code-memory store is opened lazily when a configured database file
    /// appears. Chat owns first-use database creation on a fresh profile, so
    /// opening this store only during daemon init would leave code/memory RPCs
    /// unavailable until the next restart.
    private var projectCodeMemoryStorage: BurnBarProjectCodeMemoryStore?
    private var projectCodeMemoryBootstrapAttempted = false
    private var projectCodeMemoryBootstrapFailure: String?
    var projectCodeMemory: BurnBarProjectCodeMemoryStore? {
        ensureProjectCodeMemoryBootstrapped()
    }
    let databaseRecoveryService: BurnBarDatabaseRecoveryBundleService?
    let textExpansionService: BurnBarTextExpansionService?
    var resumeService: BurnBarResumeService?
    /// The AI Inbox is opened lazily for the same reason as code memory: chat
    /// owns first-use database creation on a fresh profile, so binding it at
    /// init would leave the inbox unavailable until the next daemon restart.
    private var aiInboxStorage: BurnBarAIInboxService?
    private var aiInboxBootstrapAttempted = false
    /// Last bootstrap failure (cleared on success / forced retry). Surfaced in
    /// inbox RPC errors so Settings does not claim the index path is missing
    /// when the real problem is cipher/key/schema.
    private var aiInboxBootstrapFailure: String?
    var aiInbox: BurnBarAIInboxService? {
        ensureAIInboxBootstrapped()
    }

    /// Human-readable reason the AI Inbox control plane is unavailable, or nil
    /// when the service is ready. Used by RPC error payloads.
    var aiInboxUnavailabilityReason: String? {
        if aiInboxStorage != nil { return nil }
        if let aiInboxBootstrapFailure {
            return aiInboxBootstrapFailure
        }
        let path = configuration.indexDatabasePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            return "The AI Inbox is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
        }
        if FileManager.default.fileExists(atPath: path) == false {
            return "The AI Inbox is waiting for the index database at \(path) to be created."
        }
        return "The AI Inbox is not available yet."
    }
    let ownsChatThreadService: Bool
    private let gatewayServer: BurnBarHTTPGatewayServer?
    private let rateLimiter: BurnBarRateLimiter?
    private var listenerFileDescriptor: Int32?
    private var socketOwnership: BurnBarDaemonSocketOwnership?
    private var boundSocketIdentity: BurnBarSocketIdentity?
    private var acceptLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var oauthRefreshTask: Task<Void, Never>?
    private var localUsageIngestionTask: Task<Void, Never>?
    private var aiInboxStartedLoop = false
    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        localUsageIngestionService: BurnBarLocalUsageIngestionService? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        quotaSignalStore: BurnBarQuotaSignalStore? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil,
        computerUseService: ComputerUseService? = nil,
        computerUseAuthorizationRegistry: ComputerUseAuthorizationRegistry? = nil,
        missionControlService: (any BurnBarMissionControlServing)? = nil,
        membershipService: (any BurnBarMembershipServing)? = nil,
        rateLimiter: BurnBarRateLimiter? = nil,
        peerAuthenticator: BurnBarDaemonPeerAuthenticator = .disabled,
        capabilityProfile: BurnBarPeerCapabilityProfile = .full,
        localAuthProofVerifier: DaemonLocalAuthProofVerifier? = nil,
        phoneControlPinStore: DaemonPhoneKeyPinStore? = nil,
        computerUseApprovalAuthorityVerifier: DaemonComputerUseApprovalAuthorityVerifier? = nil,
        computerUseSessionGrantBroker: ComputerUseSessionGrantBroker? = nil,
        computerUseSessionGrantMetadataResolver: ComputerUseSessionGrantMetadataResolver? = nil,
        computerUseSessionGrantReadinessProvider: ComputerUseSessionGrantReadinessProvider? = nil,
        linuxIrohControllerCredentialProvider: LinuxIrohControllerCredentialProvider? = nil,
        linuxCloudCredentialAuthority: LinuxDaemonCloudCredentialAuthority? = nil,
        linuxTrustedDeviceManager: (any LinuxTrustedDeviceManaging)? = nil,
        linuxCloudSyncRuntime: LinuxCloudSyncRuntime? = nil,
        linuxComputerUseOwnerAuthorizer: LinuxComputerUseOwnerAuthorizer? = nil,
        linuxOnboardingService: BurnBarLinuxOnboardingService? = nil,
        linuxPrivacyService: BurnBarLinuxPrivacyService? = nil,
        subscriptionService: BurnBarSubscriptionService? = nil,
        chatThreadService: (any BurnBarChatThreadServing)? = nil,
        fleetService: BurnBarFleetService? = nil,
        flameService: BurnBarFlameService? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        self.connectionGate = BurnBarConnectionGate()
        self.peerAuthenticator = peerAuthenticator
        self.capabilityProfile = capabilityProfile
        self.localAuthProofVerifier = localAuthProofVerifier
        self.phoneControlPinStore = phoneControlPinStore
        #if os(Linux)
        self.linuxCloudCredentialAuthority = linuxCloudCredentialAuthority
        self.linuxTrustedDeviceManager = linuxTrustedDeviceManager
        self.linuxCloudSyncRuntime = linuxCloudSyncRuntime
        if let linuxComputerUseOwnerAuthorizer {
            self.linuxComputerUseOwnerAuthorizer = linuxComputerUseOwnerAuthorizer
        } else {
            let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator()
            self.linuxComputerUseOwnerAuthorizer = { peerProcessID, operationID, reason in
                _ = try await coordinator.authorize(
                    peerProcessID: peerProcessID,
                    operationID: operationID,
                    reason: reason
                )
            }
        }
        #else
        _ = linuxCloudCredentialAuthority
        _ = linuxCloudSyncRuntime
        // Production macOS callers leave this nil. Retaining an explicitly
        // injected verifier keeps the transport authority path testable on
        // non-Linux CI without enabling it by default.
        self.computerUseApprovalAuthorityVerifier = computerUseApprovalAuthorityVerifier
        self.computerUsePanicAuthorityVerifier = nil
        self.computerUseSessionGrantBroker = computerUseSessionGrantBroker
        self.computerUseSessionGrantMetadataResolver = computerUseSessionGrantMetadataResolver
        self.computerUseSessionGrantReadinessProvider = computerUseSessionGrantReadinessProvider
        #endif
        self.subscriptionService = subscriptionService ?? BurnBarSubscriptionService(
            daemonVersion: configuration.daemonVersion
        )
        self.chatThreadService = chatThreadService
        self.ownsChatThreadService = chatThreadService == nil
        self.fleetService = fleetService ?? BurnBarFleetServiceFactory.makeDefault(configuration: configuration)
        self.flameService = flameService ?? BurnBarFlameServiceFactory.makeDefault()

        let resolvedConfigStore = configStore ?? BurnBarConfigStore(
            catalog: configuration.catalog,
            logger: BurnBarDaemonLogger(category: "config-store")
        )
        self.linuxOnboardingService = linuxOnboardingService ?? BurnBarLinuxOnboardingService(
            providerCatalogCount: configuration.catalog.providers.count,
            configStore: resolvedConfigStore
        )
        let resolvedUsageRecorder = usageRecorder ?? BurnBarUsageRecorder(
            logger: BurnBarDaemonLogger(category: "usage-recorder")
        )
        #if os(Linux)
        let resolvedLocalUsageIngestionService = localUsageIngestionService
            ?? BurnBarLocalUsageIngestionService.linuxDefault(usageRecorder: resolvedUsageRecorder)
        #else
        let resolvedLocalUsageIngestionService = localUsageIngestionService
        #endif
        let resolvedProxyRouteLogStore = proxyRouteLogStore ?? BurnBarProxyRouteLogStore(
            logger: BurnBarDaemonLogger(category: "proxy-route-log")
        )
        let resolvedQuotaSignalStore = quotaSignalStore ?? BurnBarQuotaSignalStore(
            logger: BurnBarDaemonLogger(category: "quota-signals")
        )
        #if os(Linux)
        let resolvedLinuxQuotaRefreshService = BurnBarLinuxQuotaRefreshService(
            configStore: resolvedConfigStore
        )
        #endif
        let resolvedClientRegistry = clientRegistry ?? BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "client-registry")
        )
        let resolvedComputerUseAuthorizationRegistry = computerUseAuthorizationRegistry
            ?? ComputerUseAuthorizationRegistry(enforcementEnabled: localAuthProofVerifier != nil)
        #if os(Linux)
        let resolvePinnedKey: @Sendable (String) -> PhoneControlVerifyingKey? = { identifier in
            guard let phoneControlPinStore,
                  case .pinned(let key) = phoneControlPinStore.pinnedKey(deviceId: identifier) else {
                return nil
            }
            return key
        }
        let resolvedApprovalVerifier: DaemonComputerUseApprovalAuthorityVerifier?
        let resolvedPanicVerifier: DaemonComputerUsePanicAuthorityVerifier?
        let resolvedGrantVerifier: DaemonComputerUseSessionGrantAuthorityVerifier?
        if let localAuthProofVerifier {
            resolvedApprovalVerifier = computerUseApprovalAuthorityVerifier
                ?? DaemonComputerUseApprovalAuthorityVerifier(
                    resolvePinnedKey: resolvePinnedKey,
                    replayCounterStore: .production()
                )
            resolvedPanicVerifier = DaemonComputerUsePanicAuthorityVerifier(
                resolvePinnedKey: resolvePinnedKey,
                replayCounterStore: .production()
            )
            resolvedGrantVerifier = DaemonComputerUseSessionGrantAuthorityVerifier(
                resolvePinnedKey: resolvePinnedKey,
                localAuthProofVerifier: localAuthProofVerifier,
                replayCounterStore: .production()
            )
        } else {
            resolvedApprovalVerifier = nil
            resolvedPanicVerifier = nil
            resolvedGrantVerifier = nil
        }
        self.computerUseApprovalAuthorityVerifier = resolvedApprovalVerifier
        self.computerUsePanicAuthorityVerifier = resolvedPanicVerifier

        let ownsProductionControllerStack = localAuthProofVerifier != nil
            && phoneControlPinStore != nil
            && computerUseService == nil
            && computerUseSessionGrantBroker == nil
            && computerUseSessionGrantMetadataResolver == nil
            && computerUseSessionGrantReadinessProvider == nil
        let resolvedIrohRuntime: LinuxIrohControllerRuntime?
        if ownsProductionControllerStack,
           let linuxIrohControllerCredentialProvider,
           let resolvedGrantVerifier,
           let resolvedApprovalVerifier,
           let resolvedPanicVerifier,
           let phoneControlPinStore {
            resolvedIrohRuntime = LinuxIrohControllerRuntime.production(
                credentialProvider: linuxIrohControllerCredentialProvider,
                phoneControlPinStore: phoneControlPinStore,
                authorityHealth: {
                    let grantHealthy = await resolvedGrantVerifier.isOperational()
                    let approvalHealthy = await resolvedApprovalVerifier.isOperational()
                    let panicHealthy = await resolvedPanicVerifier.isOperational()
                    return grantHealthy && approvalHealthy && panicHealthy
                }
            )
        } else {
            resolvedIrohRuntime = nil
        }
        self.linuxIrohControllerRuntime = resolvedIrohRuntime
        if ownsProductionControllerStack && resolvedIrohRuntime == nil {
            self.linuxIrohControllerUnavailableStatus = LinuxIrohControllerRuntime.RuntimeStatus(
                phase: .stopped,
                reason: linuxIrohControllerCredentialProvider == nil
                    ? .credentialsUnavailable
                    : .nativeTransportUnavailable,
                changedAt: Date(),
                retryAt: nil
            )
        } else {
            self.linuxIrohControllerUnavailableStatus = nil
        }

        let resolvedGrantBroker: ComputerUseSessionGrantBroker?
        if let computerUseSessionGrantBroker {
            resolvedGrantBroker = computerUseSessionGrantBroker
        } else if let resolvedIrohRuntime, let resolvedGrantVerifier {
            resolvedGrantBroker = ComputerUseSessionGrantBroker(
                publisher: { peerNodeID, frame in
                    try await resolvedIrohRuntime.publish(to: peerNodeID, frame: frame)
                },
                prevalidatePinnedPhoneGrant: { request, authorityPeerNodeID, now in
                    try await resolvedGrantVerifier.verify(
                        request,
                        expectedAuthorityPeerNodeID: authorityPeerNodeID,
                        now: now
                    )
                }
            )
        } else {
            resolvedGrantBroker = nil
        }
        self.computerUseSessionGrantBroker = resolvedGrantBroker
        let resolvedMetadataResolver: ComputerUseSessionGrantMetadataResolver?
        if let computerUseSessionGrantMetadataResolver {
            resolvedMetadataResolver = computerUseSessionGrantMetadataResolver
        } else if let runtime = resolvedIrohRuntime {
            resolvedMetadataResolver = { requirement, request in
                try await runtime.acquisitionMetadata(requirement: requirement, request: request)
            }
        } else {
            resolvedMetadataResolver = nil
        }
        self.computerUseSessionGrantMetadataResolver = resolvedMetadataResolver
        let resolvedReadinessProvider: ComputerUseSessionGrantReadinessProvider?
        if let computerUseSessionGrantReadinessProvider {
            resolvedReadinessProvider = computerUseSessionGrantReadinessProvider
        } else if let runtime = resolvedIrohRuntime {
            resolvedReadinessProvider = { await runtime.isReady() }
        } else {
            resolvedReadinessProvider = nil
        }
        self.computerUseSessionGrantReadinessProvider = resolvedReadinessProvider
        let approvalPublisher: ComputerUseService.ApprovalPublisher?
        let sessionEndedObserver: ComputerUseService.SessionEndedObserver?
        if let runtime = resolvedIrohRuntime {
            approvalPublisher = { request in try await runtime.publishApproval(request) }
            sessionEndedObserver = { sessionID in await runtime.unbindSession(sessionID) }
        } else {
            approvalPublisher = nil
            sessionEndedObserver = nil
        }
        let resolvedComputerUseService = computerUseService ?? ComputerUseService(
            authorizationRegistry: resolvedComputerUseAuthorizationRegistry,
            approvalPublisher: approvalPublisher,
            sessionEndedObserver: sessionEndedObserver
        )
        #else
        let resolvedComputerUseService = computerUseService ?? ComputerUseService(
            authorizationRegistry: resolvedComputerUseAuthorizationRegistry
        )
        #endif
        let computerUseBrowserDispatcher: BurnBarComputerUseBrowserDispatcher?
        let computerUseRunBindingChecker: BurnBarComputerUseRunBindingChecker?
        let computerUseRunRevoker: BurnBarComputerUseRunRevoker?
        #if os(Linux)
        computerUseBrowserDispatcher = { invocation in
            guard let sessionID = await resolvedComputerUseService.sessionID(for: invocation.runID),
                  await resolvedComputerUseAuthorizationRegistry.permits(
                    sessionID: sessionID,
                    invocation: invocation
                  ) else {
                throw ComputerUseService.ServiceError.authorizationExpired(invocation.runID.rawValue)
            }
            let response = try await resolvedComputerUseService.invokeForRun(invocation)
            return BurnBarComputerUseBrowserDispatchResult(
                expectedSessionID: sessionID,
                response: response
            )
        }
        computerUseRunBindingChecker = { runID, expectedGeneration in
            await resolvedComputerUseAuthorizationRegistry.hasActiveBinding(
                runID: runID,
                generation: expectedGeneration
            )
        }
        computerUseRunRevoker = { runID, expectedGeneration in
            guard let binding = await resolvedComputerUseAuthorizationRegistry.binding(runID: runID),
                  binding.generation == expectedGeneration else {
                return
            }
            await resolvedComputerUseAuthorizationRegistry.revoke(sessionID: binding.sessionID)
            _ = try? await resolvedComputerUseService.panicHalt(
                ComputerUsePanicHaltRequest(
                    sessionId: binding.sessionID.rawValue,
                    source: ComputerUsePanicSource.revoked.rawValue
                )
            )
        }
        #else
        computerUseBrowserDispatcher = nil
        computerUseRunBindingChecker = nil
        computerUseRunRevoker = nil
        #endif
        let resolvedRunService = runService ?? BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: resolvedConfigStore,
                logger: BurnBarDaemonLogger(category: "provider-router"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore()
            ),
            usageRecorder: resolvedUsageRecorder,
            clientRegistry: resolvedClientRegistry,
            computerUseBrowserDispatcher: computerUseBrowserDispatcher,
            computerUseRunBindingChecker: computerUseRunBindingChecker,
            computerUseRunRevoker: computerUseRunRevoker,
            logger: BurnBarDaemonLogger(category: "run-service")
        )

        self.configStore = resolvedConfigStore
        self.usageRecorder = resolvedUsageRecorder
        self.localUsageIngestionService = resolvedLocalUsageIngestionService
        self.proxyRouteLogStore = resolvedProxyRouteLogStore
        self.quotaSignalStore = resolvedQuotaSignalStore
        #if os(Linux)
        self.linuxQuotaRefreshService = resolvedLinuxQuotaRefreshService
        #endif
        self.clientRegistry = resolvedClientRegistry
        self.runService = resolvedRunService
        self.toolingProxy = BurnBarToolingProxyService(
            connectorPlaneService: resolvedRunService.connectorPlaneService,
            browserToolService: resolvedRunService.browserToolService
        )
        self.computerUseService = resolvedComputerUseService
        self.computerUseAuthorizationRegistry = resolvedComputerUseAuthorizationRegistry
        #if os(Linux)
        let mediaLogger = BurnBarDaemonLogger(category: "linux-media")
        self.mediaService = MercuryLinuxMediaSessionController(
            fileTransferService: MercuryLinuxFileTransferFactory.make(logger: mediaLogger),
            downloadDirectoryProvider: {
                MercuryLinuxFileTransferFactory.downloadDirectoryURL()
            },
            logger: mediaLogger
        )
        self.linuxPrivacyService = linuxPrivacyService ?? BurnBarLinuxPrivacyService()
        #endif
        self.rateLimiter = rateLimiter ?? BurnBarRateLimiter(configuration: configuration.socketRateLimit)
        // VAL-DAEMON-011: Wire a concrete execution readiness gate with fail-closed semantics.
        // When gate data is unavailable (no config, no connector plane), the gate returns a failure
        // with an explicit reason code instead of allowing dispatch to proceed (fail-open).
        //
        // Note: The readiness gate is @Sendable and runs on BurnBarMissionControlService actor.
        // We can only call async actor methods from this closure. For sync actor methods like
        // configStore.snapshot(), we rely on the fact that connectorPlaneSnapshot() validates
        // both runtime availability AND provider credentials (since connectors are backed by
        // the same credential system).
        let resolvedToolingProxy = self.toolingProxy
        let executionReadinessGate: BurnBarExecutionReadinessGate = { @Sendable _, _ in
            // Check 1: Verify connector plane runtime is accessible
            // This also implicitly validates that provider credentials are accessible since
            // the connector plane is backed by the same secret store.
            do {
                let connectorPlane = try await resolvedToolingProxy.connectorPlaneSnapshot()
                // If connector plane has no enabled/healthy connectors, runtime is unavailable
                let hasEnabledConnector = connectorPlane.connectors.contains { $0.isEnabled }
                if !hasEnabledConnector {
                    return BurnBarExecutionReadiness(
                        code: .runtimeUnavailable,
                        detail: "No connector plane runtime is configured. Configure at least one provider in OpenBurnBar Settings before dispatching missions."
                    )
                }
                // Also check that at least one connector has a valid secret (credentials configured)
                let hasConnectorWithCredentials = connectorPlane.connectors.contains { connector in
                    connector.isEnabled && connector.secretConfigured
                }
                if !hasConnectorWithCredentials {
                    return BurnBarExecutionReadiness(
                        code: .missingCredential,
                        detail: "No AI provider credentials are configured. Add provider credentials in OpenBurnBar Settings before dispatching missions."
                    )
                }
            } catch {
                return BurnBarExecutionReadiness(
                    code: .runtimeUnavailable,
                    detail: "Connector plane runtime is unavailable: \(error.localizedDescription)"
                )
            }

            // All checks passed - mission is ready to dispatch
            return nil
        }

        self.missionControlService = missionControlService ?? BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                logger: BurnBarDaemonLogger(category: "mission-control-store")
            ),
            logger: BurnBarDaemonLogger(category: "mission-control-service"),
            activitySnapshotURL: BurnBarDaemonPaths.defaultControllerActivitySnapshotURL,
            reviewRunLauncher: { prompt, modelID, metadata in
                try await resolvedRunService.createDaemonManagedRun(
                    prompt: prompt,
                    modelID: modelID,
                    metadata: metadata
                )
            },
            runSnapshotLookup: { runID in
                await resolvedRunService.snapshot(for: runID)
            },
            executionReadinessGate: executionReadinessGate
        )
        self.membershipService = membershipService ?? BurnBarMembershipService()

        if let path = configuration.indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false {
            self.databaseRecoveryService = BurnBarDatabaseRecoveryBundleService(
                databasePath: path,
                logger: BurnBarDaemonLogger(category: "database-recovery")
            )
#if os(Linux)
            // Match macOS's encryption-at-rest default on first launch. The
            // key is persisted in the approved native SecretStore before the
            // chat store can create the database; encrypted existing profiles
            // without a readable key remain fail-closed.
            do {
                _ = try BurnBarDaemonDatabaseCipher.ensureKeyIfNeeded(at: path)
            } catch {
                logger.warning(
                    "daemon_database_key_provision_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }
#endif
            if FileManager.default.fileExists(atPath: path) {
                // RR-1: one-time plaintext→encrypted migration of the shared SQLite
                // file BEFORE any service opens it. No-op on a stock-SQLite build or
                // when no key is provisioned, so the disclosed-plaintext file is left
                // exactly as-is (do-not-brick). On failure we log and continue —
                // the original plaintext file is untouched and still opens below.
                do {
                    _ = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
                        at: path,
                        logger: BurnBarDaemonLogger(category: "database-cipher")
                    )
                } catch {
                    logger.warning(
                        "daemon_database_encrypted_migration_failed",
                        metadata: ["path": path, "error": "\(error)"]
                    )
                }
                do {
                    self.indexedSearch = try BurnBarIndexedSearchService(
                        databasePath: path,
                        logger: BurnBarDaemonLogger(category: "indexed-search")
                    )
                } catch {
                    logger.warning(
                        "indexed_search_init_failed",
                        metadata: ["path": path, "error": "\(error)"]
                    )
                    self.indexedSearch = nil
                }
                do {
                    self.resumeService = try BurnBarResumeService(
                        databasePath: path,
                        logger: BurnBarDaemonLogger(category: "resume-service")
                    )
                } catch {
                    logger.warning(
                        "resume_service_init_failed",
                        metadata: ["path": path, "error": "\(error)"]
                    )
                    self.resumeService = nil
                }
                do {
                    self.projectCodeMemoryStorage = try BurnBarProjectCodeMemoryStore(
                        databasePath: path,
                        logger: BurnBarDaemonLogger(category: "project-code-memory")
                    )
                    self.projectCodeMemoryBootstrapAttempted = true
                } catch {
                    logger.warning(
                        "project_code_memory_init_failed",
                        metadata: ["path": path, "error": "\(error)"]
                    )
                    self.projectCodeMemoryStorage = nil
                    self.projectCodeMemoryBootstrapAttempted = true
                    self.projectCodeMemoryBootstrapFailure = error.localizedDescription
                }
            } else {
                // Chat opens the database below with SQLITE_OPEN_CREATE. Leave
                // code memory unattempted so its first RPC can bootstrap after
                // chat (or another database owner) creates the file.
                self.indexedSearch = nil
                self.resumeService = nil
                self.projectCodeMemoryStorage = nil
            }
            // The chat thread store must NOT be gated on the file existing: it
            // opens with SQLITE_OPEN_CREATE so the very first chat on a fresh
            // profile creates `openburnbar.sqlite`. Gating it above left fresh
            // Linux profiles with permanently unavailable chat RPCs.
            if self.chatThreadService == nil {
                do {
                    self.chatThreadService = try BurnBarChatThreadService(
                        databasePath: path,
                        logger: BurnBarDaemonLogger(category: "chat-thread-store")
                    )
                } catch {
                    logger.warning(
                        "chat_thread_service_init_failed",
                        metadata: ["path": path, "error": "\(error)"]
                    )
                }
            }
        } else {
            self.indexedSearch = nil
            self.projectCodeMemoryStorage = nil
            self.databaseRecoveryService = nil
            self.resumeService = nil
        }

        #if os(Linux)
        self.textExpansionService = BurnBarTextExpansionService(
            logger: BurnBarDaemonLogger(category: "text-expansion")
        )
        #else
        self.textExpansionService = nil
        #endif

        // HTTP gateway — only initialized if enabled.
        if configuration.gateway.isEnabled {
            self.gatewayServer = BurnBarHTTPGatewayServer(
                configuration: configuration.gateway,
                configStore: resolvedConfigStore,
                usageRecorder: resolvedUsageRecorder,
                proxyRouteLogStore: resolvedProxyRouteLogStore,
                quotaSignalStore: resolvedQuotaSignalStore,
                // remediation(B1): production daemon opts into the short-TTL
                // live model-catalog cache so `/v1/models` and the routing path
                // stop fanning out live provider HTTP (and spawning Factory's
                // `droid exec --help`) on every request.
                modelCatalogCacheTTL: BurnBarHTTPGatewayServer.defaultModelCatalogCacheTTL,
                logger: BurnBarDaemonLogger(category: "http-gateway")
            )
        } else {
            self.gatewayServer = nil
        }
    }

    /// Opens the AI Inbox service after the configured database path becomes a
    /// real file. A missing file is not a failed attempt (chat may create it).
    /// Permanent open failures are sticky; transient lock/busy failures leave
    /// the door open for the next RPC / Settings Retry.
    @discardableResult
    func ensureAIInboxBootstrapped(forceRetry: Bool = false) -> BurnBarAIInboxService? {
        if let aiInboxStorage {
            return aiInboxStorage
        }
        if forceRetry {
            aiInboxBootstrapAttempted = false
            aiInboxBootstrapFailure = nil
        }
        guard aiInboxBootstrapAttempted == false else { return nil }
        guard let path = configuration.indexDatabasePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            path.isEmpty == false,
            FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let service = try BurnBarAIInboxService(
                databasePath: path,
                usageRecorder: usageRecorder,
                configStore: configStore
            )
            aiInboxStorage = service
            aiInboxBootstrapFailure = nil
            aiInboxBootstrapAttempted = true
            logger.info("ai_inbox_bootstrap_succeeded", metadata: ["path": path])
            // Late bootstrap (index database created after daemon startup, or
            // a Settings → Retry) must still start the periodic loop — startup
            // only starts it when bootstrap succeeded there and then. Without
            // this, a fresh profile gets a service that answers RPCs but never
            // ticks in the background until the daemon restarts.
            if configuration.startsMissionControlBackgroundLoops, aiInboxStartedLoop == false {
                Task { await service.start() }
                aiInboxStartedLoop = true
            }
            return service
        } catch {
            let detail = error.localizedDescription
            aiInboxBootstrapFailure = detail
            let transient = Self.isTransientAIInboxBootstrapFailure(detail)
            // Sticky only for permanent failures so a SQLITE_BUSY blip during
            // app ingestion cannot disable the inbox until the next reboot.
            aiInboxBootstrapAttempted = (transient == false)
            logger.warning(
                "ai_inbox_bootstrap_failed",
                metadata: [
                    "path": path,
                    "error": detail,
                    "transient": transient ? "true" : "false"
                ]
            )
            return nil
        }
    }

    private static func isTransientAIInboxBootstrapFailure(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("busy")
            || lowered.contains("locked")
            || lowered.contains("database is locked")
            || lowered.contains("sqlite_busy")
            || lowered.contains("sqlite_locked")
    }

    /// Opens the project code-memory store exactly once after the configured
    /// database path becomes a real file. This method is actor-isolated through
    /// `BurnBarDaemonServer`, so concurrent RPCs cannot race store construction.
    ///
    /// A missing file is deliberately not considered a failed attempt: the
    /// chat service creates it on first use for a fresh profile. Once a file is
    /// present, however, any open/schema/key failure is cached and remains
    /// unavailable until the daemon restarts. That avoids retry storms and
    /// keeps the RPC surface fail closed without ever opening an unconfigured
    /// or plaintext fallback database.
    @discardableResult
    func ensureProjectCodeMemoryBootstrapped() -> BurnBarProjectCodeMemoryStore? {
        if let projectCodeMemoryStorage {
            return projectCodeMemoryStorage
        }
        guard projectCodeMemoryBootstrapAttempted == false else {
            return nil
        }
        guard let path = configuration.indexDatabasePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            path.isEmpty == false,
            FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        // Only mark the attempt after the configured file exists. The chat
        // store may create that file after the daemon has initialized.
        projectCodeMemoryBootstrapAttempted = true
        do {
            // Keep the same migration/key ordering as daemon initialization.
            // The helper never creates an unconfigured plaintext fallback.
            do {
                _ = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
                    at: path,
                    logger: BurnBarDaemonLogger(category: "database-cipher")
                )
            } catch {
                logger.warning(
                    "daemon_database_encrypted_migration_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }
            let store = try BurnBarProjectCodeMemoryStore(
                databasePath: path,
                logger: BurnBarDaemonLogger(category: "project-code-memory")
            )
            projectCodeMemoryStorage = store
            projectCodeMemoryBootstrapFailure = nil
            logger.info(
                "project_code_memory_lazy_bootstrap_succeeded",
                metadata: ["path": path]
            )
            return store
        } catch {
            projectCodeMemoryBootstrapFailure = error.localizedDescription
            logger.warning(
                "project_code_memory_lazy_bootstrap_failed",
                metadata: ["path": path, "error": error.localizedDescription]
            )
            return nil
        }
    }

    /// Entry point for the authenticated paired-controller transport. The
    /// transport must pass the peer identity established by its own handshake;
    /// renderer/socket fields are never accepted as that identity.
    public func ingestComputerUseSessionGrant(
        _ request: HermesRealtimeRelayAgentGrantRequest,
        authenticatedTransportPeerNodeID: String,
        now: Date = Date()
    ) async throws {
        guard let computerUseSessionGrantBroker else {
            throw ComputerUseSessionGrantBroker.BrokerError.transportUnavailable
        }
        try await computerUseSessionGrantBroker.ingest(
            request,
            authenticatedTransportPeerNodeID: authenticatedTransportPeerNodeID,
            now: now
        )
    }

    func ingestComputerUseApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        sessionID: String,
        provenance: ComputerUseIngressProvenance
    ) async throws {
        guard let verifier = computerUseApprovalAuthorityVerifier else {
            throw ComputerUseTransportIngressError.rejected
        }
        #if os(Linux)
        if let linuxIrohControllerRuntime {
            guard case .authenticatedIrohTransport(let transportPeerNodeID, let routeGeneration) = provenance,
                  let authorityPeerNodeID = response.authority?.peerNodeId,
                  response.respondedBy == authorityPeerNodeID,
                  await linuxIrohControllerRuntime.authorizesSessionAuthority(
                    sessionID: sessionID,
                    authorityPeerNodeID: authorityPeerNodeID,
                    transportPeerNodeID: transportPeerNodeID,
                    routeGeneration: routeGeneration
                  ) else {
                throw ComputerUseTransportIngressError.rejected
            }
        }
        #endif
        let pending = await computerUseService.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: sessionID)
        ).requests.first { $0.approvalId == response.approvalId }
        guard let pending else { throw ComputerUseTransportIngressError.rejected }
        try await verifier.verify(response: response, pendingRequest: pending, sessionID: sessionID)
        guard await computerUseService.respondToApproval(
            ComputerUseApprovalRespondRequest(sessionId: sessionID, response: response)
        ).accepted else {
            throw ComputerUseTransportIngressError.rejected
        }
    }

    #if os(Linux)
    func linuxIrohControllerStatus() async -> LinuxIrohControllerRuntime.RuntimeStatus? {
        if let linuxIrohControllerRuntime { return await linuxIrohControllerRuntime.status() }
        return linuxIrohControllerUnavailableStatus
    }

    public func handleLinuxCloudAuthSessionEvent(_ event: LinuxCloudAuthSessionEvent) async {
        guard let linuxIrohControllerRuntime else { return }
        switch event {
        case .credentialsAvailable:
            do {
                try await linuxIrohControllerRuntime.start()
            } catch {
                logger.warning(
                    "linux_iroh_controller_credential_restart_failed",
                    metadata: ["reason": "unavailable"]
                )
            }
        case .invalidated:
            await linuxIrohControllerRuntime.stop()
        }
    }

    public func handleLinuxCloudAuthTeardown(
        credentials: LinuxIrohControllerCredentialContext?
    ) async {
        guard let linuxIrohControllerRuntime else { return }
        await linuxIrohControllerRuntime.stop(teardownCredentials: credentials)
    }

    public func linuxCloudAuthStatus() async -> BurnBarLinuxAuthStatusResponse {
        guard let linuxCloudCredentialAuthority else {
            return BurnBarLinuxAuthStatusResponse(
                state: .unavailable,
                signedIn: false,
                detail: "credential_authority_unavailable"
            )
        }
        return await linuxCloudCredentialAuthority.status()
    }

    public func beginLinuxCloudSignIn() async throws -> BurnBarLinuxAuthBeginResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        return try await linuxCloudCredentialAuthority.beginSignIn()
    }

    public func cancelLinuxCloudSignIn(operationID: String) async throws -> BurnBarLinuxAuthStatusResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        try await linuxCloudCredentialAuthority.cancelSignIn(operationID: operationID)
        return await linuxCloudCredentialAuthority.status()
    }

    public func signOutLinuxCloud() async throws -> BurnBarLinuxAuthStatusResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        try await linuxCloudCredentialAuthority.signOut()
        return await linuxCloudCredentialAuthority.status()
    }

    public func rotateLinuxCloudInstallationIdentity() async throws -> BurnBarLinuxAuthStatusResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        try await linuxCloudCredentialAuthority.rotateInstallationIdentity()
        return await linuxCloudCredentialAuthority.status()
    }

    /// Execute the canonical server-owned account erasure through the Linux
    /// credential authority. The renderer supplies only the confirmation
    /// phrase; trusted-device authorization, Firebase credentials, and the
    /// callable request remain daemon-owned.
    public func deleteLinuxAccountCloudData(
        confirmation: String
    ) async throws -> BurnBarLinuxAccountCloudDataDeletionResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        let result = try await linuxCloudCredentialAuthority.requestCloudDataDeletion(
            confirmationToken: confirmation
        )
        return BurnBarLinuxAccountCloudDataDeletionResponse(
            ok: result.success,
            cloudDataDeleted: result.cloudDataDeleted,
            retryRequired: result.retryRequired,
            deletedDocuments: result.deletedDocuments,
            destroyedSecrets: result.destroyedSecrets,
            failedSecretDestroys: result.failedSecretDestroys,
            deletedStoragePrefixes: result.deletedStoragePrefixes,
            failedStorageDeletes: result.failedStorageDeletes,
            deletedAuthUser: result.deletedAuthUser,
            authUserAlreadyMissing: result.authUserAlreadyMissing
        )
    }

    /// Execute the canonical server-owned account export through the Linux
    /// credential authority, then write the bounded payload to a daemon-
    /// validated owner-only path. Cloud credentials and export bytes never
    /// cross the renderer bridge.
    public func exportLinuxAccountCloudData(
        domains: [String]?,
        destinationPath: String
    ) async throws -> BurnBarLinuxAccountCloudDataExportResponse {
        guard let linuxCloudCredentialAuthority else {
            throw LinuxCloudAuthAuthorityError.configurationRequired
        }
        let data = try await linuxCloudCredentialAuthority.requestCloudDataExport(domains: domains)
        let receipt = try await linuxPrivacyService.writePlaintextExport(
            data,
            destinationPath: destinationPath
        )
        return BurnBarLinuxAccountCloudDataExportResponse(
            ok: true,
            destinationPath: receipt.destinationPath,
            byteCount: Int(receipt.byteCount),
            schemaVersion: 2
        )
    }
    #endif

    func ingestComputerUsePanic(
        _ intent: HermesRealtimeRelayInputIntent,
        sessionIDs: [String],
        authenticatedTransportPeerNodeID: String,
        authorityPeerNodeID: String
    ) async throws {
        guard authenticatedTransportPeerNodeID.isEmpty == false,
              let verifier = computerUsePanicAuthorityVerifier else {
            throw ComputerUseTransportIngressError.rejected
        }
        try await verifier.verify(
            intent: intent,
            expectedAuthorityPeerNodeID: authorityPeerNodeID
        )
        for sessionID in sessionIDs {
            _ = try? await computerUseService.panicHalt(
                ComputerUsePanicHaltRequest(
                    sessionId: sessionID,
                    source: ComputerUsePanicSource.phoneGesture.rawValue
                )
            )
        }
    }

    public func start() async throws {
        try configuration.validate()

        // Defense-in-depth: validate() guarantees socketAuthToken is non-nil, so
        // this assert can only fire if that invariant is broken. Using assert
        // (not precondition) because it documents a structurally-impossible
        // state rather than a runtime error a release build should crash on.
        assert(peerAuthenticator.isEnforced || configuration.socketAuthToken != nil)

        guard listenerFileDescriptor == nil else {
            logger.debug(
                "bootstrap_start_skipped",
                metadata: ["socket_path": configuration.socketPath]
            )
            return
        }

        logger.info(
            "bootstrap_starting",
            metadata: [
                "socket_path": configuration.socketPath,
                "daemon_version": configuration.daemonVersion,
                "protocol_version": "\(BurnBarProtocolVersion.current)"
            ]
        )

        try BurnBarUnixDomainSocket.ensureParentDirectory(for: configuration.socketPath)
        let ownership = try BurnBarDaemonSocketOwnership.acquire(for: configuration.socketPath)
        var startupFileDescriptor: Int32?
        var startupSocketIdentity: BurnBarSocketIdentity?
        do {
            if try BurnBarUnixDomainSocket.preparePathForBind(at: configuration.socketPath) {
                logger.notice(
                    "stale_socket_removed",
                    metadata: [
                        "socket_path": configuration.socketPath,
                        "item_type": "socket"
                    ]
                )
            }

            let fileDescriptor = try BurnBarUnixDomainSocket.makeListeningSocket(at: configuration.socketPath)
            startupFileDescriptor = fileDescriptor
            let identity = try BurnBarUnixDomainSocket.socketIdentity(at: configuration.socketPath)
            startupSocketIdentity = identity
            try BurnBarUnixDomainSocket.restrictSocketPermissions(at: configuration.socketPath)
            listenerFileDescriptor = fileDescriptor
            socketOwnership = ownership
            boundSocketIdentity = identity
        } catch {
            if let startupFileDescriptor {
                close(startupFileDescriptor)
            }
            if let startupSocketIdentity {
                _ = try? BurnBarUnixDomainSocket.removeSocket(
                    at: configuration.socketPath,
                    ifIdentityMatches: startupSocketIdentity
                )
            }
            ownership.release()
            throw error
        }

        guard let fileDescriptor = listenerFileDescriptor else {
            ownership.release()
            throw BurnBarDaemonError.failedToCreateSocket(code: EIO, detail: "listener ownership was not retained")
        }

        do {
            try await configStore.seedDefaultModelVariantsIfNeeded()
        } catch {
            logger.warning(
                "default_model_variants_seed_failed",
                metadata: ["error": "\(error)"]
            )
        }

        acceptLoopTask = Task.detached(priority: .background) { [logger, connectionGate] in
            await Self.runAcceptLoop(
                server: self,
                listenerFileDescriptor: fileDescriptor,
                connectionGate: connectionGate,
                logger: logger
            )
        }
        heartbeatTask = BurnBarDaemonHeartbeat.startPeriodicWriter(
            daemonVersion: configuration.daemonVersion
        )
        oauthRefreshTask = Self.startOAuthRefreshTimer(
            configStore: configStore,
            logger: logger
        )
        if let localUsageIngestionService {
            localUsageIngestionTask = Task.detached(priority: .background) { [logger] in
                while !Task.isCancelled {
                    let report = await localUsageIngestionService.refresh()
                    if report.failures.isEmpty {
                        logger.debug(
                            "local_usage_ingestion_completed",
                            metadata: [
                                "parsed_rows": "\(report.parsedRows)",
                                "inserted_deltas": "\(report.insertedDeltas)",
                                "unchanged_rows": "\(report.unchangedRows)"
                            ]
                        )
                    } else {
                        logger.warning(
                            "local_usage_ingestion_degraded",
                            metadata: [
                                "failure_count": "\(report.failures.count)",
                                "first_failure": report.failures[0]
                            ]
                        )
                    }
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        break
                    }
                }
            }
        }
        #if os(Linux)
        do {
            try await mediaService.start()
        } catch {
            logger.warning(
                "media_channel_start_failed",
                metadata: ["error": "\(error)"]
            )
        }
        if let linuxIrohControllerRuntime {
            await linuxIrohControllerRuntime.installHandlers(
                grant: { [weak self] request, transportPeerNodeID in
                    guard let self else { throw LinuxIrohControllerRuntime.RuntimeError.handlersUnavailable }
                    try await self.ingestComputerUseSessionGrant(
                        request,
                        authenticatedTransportPeerNodeID: transportPeerNodeID
                    )
                },
                approval: { [weak self] sessionID, response, transportPeerNodeID, routeGeneration in
                    guard let self else { throw LinuxIrohControllerRuntime.RuntimeError.handlersUnavailable }
                    try await self.ingestComputerUseApprovalResponse(
                        response,
                        sessionID: sessionID,
                        provenance: .authenticatedIrohTransport(
                            peerNodeID: transportPeerNodeID,
                            routeGeneration: routeGeneration
                        )
                    )
                },
                panic: { [weak self] sessionIDs, intent, transportPeerNodeID, authorityPeerNodeID in
                    guard let self else { throw LinuxIrohControllerRuntime.RuntimeError.handlersUnavailable }
                    try await self.ingestComputerUsePanic(
                        intent,
                        sessionIDs: sessionIDs,
                        authenticatedTransportPeerNodeID: transportPeerNodeID,
                        authorityPeerNodeID: authorityPeerNodeID
                    )
                },
                revokeSessions: { [weak self] sessionIDs, _ in
                    guard let self else { return }
                    for sessionID in sessionIDs {
                        _ = try? await self.computerUseService.panicHalt(
                            ComputerUsePanicHaltRequest(
                                sessionId: sessionID,
                                source: ComputerUsePanicSource.revoked.rawValue
                            )
                        )
                    }
                },
                routeEnded: { [weak self] route, reason in
                    guard let self else { return }
                    await self.mediaService.routeEnded(
                        uid: route.uid,
                        connectionID: route.connectionID,
                        remotePeerNodeID: route.transportNodeID,
                        reason: reason
                    )
                },
                media: { [weak self] frame, remotePeerNodeID, replySender in
                    guard let self else { return }
                    await self.mediaService.ingestMercuryFrame(
                        frame,
                        remotePeerNodeID: remotePeerNodeID,
                        replySender: replySender
                    )
                }
            )
            do {
                try await linuxIrohControllerRuntime.start()
            } catch {
                logger.warning(
                    "linux_iroh_controller_start_failed",
                    metadata: ["reason": "unavailable"]
                )
            }
        }
        #endif
        #if os(Linux)
        await linuxCloudSyncRuntime?.startBackgroundLoop()
        #endif
        await fleetService.start()

        if configuration.startsMissionControlBackgroundLoops {
            await missionControlService.startBackgroundLoops()
            // Reuses the mission-control loop flag so in-process test servers do
            // not spawn a background analyst. The inbox is additionally gated by
            // its own persisted `enabled` flag, which is false until the user
            // opts in — the loop wakes, sees disabled, and goes back to sleep.
            if let inbox = ensureAIInboxBootstrapped() {
                await inbox.start()
                aiInboxStartedLoop = true
            }
        } else {
            logger.debug(
                "mission_control_background_loops_disabled",
                metadata: ["socket_path": configuration.socketPath]
            )
        }

        logger.notice(
            "bootstrap_ready",
            metadata: ["socket_path": configuration.socketPath]
        )

        // Start HTTP gateway if configured
        if let gatewayServer {
            do {
                try await gatewayServer.start()
            } catch {
                logger.error(
                    "gateway_start_failed",
                    metadata: ["error": "\(error)"]
                )
            }
        }
    }

    /// Background timer that proactively refreshes Anthropic OAuth credentials
    /// before they expire. Runs every 30 minutes. On each tick, it reads all
    /// Anthropic credential slots, refreshes any token that will expire within
    /// 1 hour, and updates the Keychain. When a refresh fails (revoked refresh
    /// token), the next `secret(for:)` call will automatically fall through to
    /// the Claude Code credential fallback.
    private static func startOAuthRefreshTimer(
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            let interval: UInt64 = 30 * 60 // 30 minutes
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let slotKeys = await configStore.oAuthSlotKeysForProactiveRefresh()
                guard !slotKeys.isEmpty else { continue }
                logger.debug(
                    "oauth_proactive_refresh_tick",
                    metadata: ["slot_count": "\(slotKeys.count)"]
                )
                await configStore.proactivelyRefreshExpiringOAuthCredentials(
                    slotKeys: slotKeys
                )
            }
        }
    }

    public func stop() async {
        guard let listenerFileDescriptor else {
            logger.debug(
                "shutdown_skipped",
                metadata: ["socket_path": configuration.socketPath]
            )
            return
        }

        logger.info(
            "shutdown_starting",
            metadata: ["socket_path": configuration.socketPath]
        )

        self.listenerFileDescriptor = nil
        let ownership = socketOwnership
        socketOwnership = nil
        let socketIdentity = boundSocketIdentity
        boundSocketIdentity = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        oauthRefreshTask?.cancel()
        oauthRefreshTask = nil
        localUsageIngestionTask?.cancel()
        localUsageIngestionTask = nil
        if aiInboxStartedLoop, let aiInboxStorage {
            await aiInboxStorage.stop()
            aiInboxStartedLoop = false
        }
        let acceptTask = acceptLoopTask
        acceptLoopTask = nil
        acceptTask?.cancel()

        shutdown(listenerFileDescriptor, Int32(SHUT_RDWR))
        close(listenerFileDescriptor)
        _ = await acceptTask?.result

        do {
            if let socketIdentity {
                let removed = try BurnBarUnixDomainSocket.removeSocket(
                    at: configuration.socketPath,
                    ifIdentityMatches: socketIdentity
                )
                if removed == false {
                    logger.warning(
                        "socket_cleanup_skipped_identity_mismatch",
                        metadata: ["socket_path": configuration.socketPath]
                    )
                }
            }
        } catch {
            logger.warning(
                "remove_owned_socket_failed",
                metadata: ["socket_path": configuration.socketPath, "error": "\(error)"]
            )
        }
        ownership?.release()
        await fleetService.stop()
        await missionControlService.stopBackgroundLoops()
        #if os(Linux)
        await linuxCloudSyncRuntime?.stopBackgroundLoop()
        await linuxIrohControllerRuntime?.stop()
        await mediaService.stop()
        #endif

        // Stop HTTP gateway
        if let gatewayServer {
            await gatewayServer.stop()
        }

        logger.notice(
            "shutdown_complete",
            metadata: ["socket_path": configuration.socketPath]
        )
    }

    public func healthResponse() -> BurnBarHealthResponse {
        BurnBarHealthResponse(
            ok: true,
            daemonVersion: configuration.daemonVersion,
            protocolVersion: BurnBarProtocolVersion.current,
            socketPath: configuration.socketPath,
            gatewayEnabled: configuration.gateway.isEnabled,
            gatewayHost: configuration.gateway.isEnabled ? configuration.gateway.host : nil,
            gatewayPort: configuration.gateway.isEnabled ? configuration.gateway.port : nil
        )
    }

    private func responseData(for requestData: Data) async -> Data {
        await responseData(for: requestData, peerPID: nil)
    }

    private func responseData(
        for requestData: Data,
        peerPID: pid_t?,
        peerCapabilityProfile: BurnBarPeerCapabilityProfile? = nil
    ) async -> Data {
        let rpcStartedAt = ContinuousClock.now
        defer {
            let elapsed = rpcStartedAt.duration(to: ContinuousClock.now)
            let milliseconds = Int(elapsed.components.seconds * 1000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: milliseconds)
        }
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)
            BurnBarDaemonMetricsCounters.recordRPCRequest()

            if let requiredToken = configuration.socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let providedToken = incomingRequest.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                guard let providedToken, constantTimeTokensEqual(providedToken, requiredToken) else {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_request_unauthorized",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": peerPID.map(String.init) ?? "unknown"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Unauthorized OpenBurnBar RPC request."
                    )
                }
            }

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.error(
                    "rpc_method_not_found",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Unsupported OpenBurnBar RPC method '\(incomingRequest.method)'."
                )
            }

            // T-DMN-01: per-operation capability attenuation. Refuse — fail closed
            // — any method whose capability group is outside this peer's scoped
            // profile, BEFORE the rate limiter or any handler runs. This bounds
            // what an authenticated-but-compromised first-party peer may do.
            let effectiveCapabilityProfile = peerCapabilityProfile
                .map { capabilityProfile.attenuated(to: $0) }
                ?? capabilityProfile
            guard effectiveCapabilityProfile.permits(method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.warning(
                    "rpc_request_capability_denied",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method,
                        "capability": BurnBarRPCCapability.capability(for: method).rawValue,
                        "peer_pid": peerPID.map(String.init) ?? "unknown"
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.unauthorized,
                    message: "OpenBurnBar RPC method '\(incomingRequest.method)' is outside this peer's capability scope."
                )
            }

            // Rate limiting check (per peer PID)
            if let rateLimiter {
                let clientKey = peerPID.map(String.init) ?? "unknown"
                let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
                if case .throttled(let retryAfter) = limitResult {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_rate_limit_exceeded",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": clientKey,
                            "retry_after": "\(retryAfter)"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.rateLimitExceeded,
                        message: "Rate limit exceeded. Retry after \(String(format: "%.1f", retryAfter)) seconds."
                    )
                }
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method, authToken: incomingRequest.authToken)

            switch method {
            case .linuxAuthStatus, .linuxAuthBegin, .linuxAuthCancel,
                 .linuxAuthRotateIdentity, .linuxAuthSignOut,
                 .linuxAccountCloudDataExport,
                 .linuxAccountCloudDataDelete, .linuxTrustedDeviceList,
                 .linuxTrustedDeviceApprove, .linuxTrustedDeviceRevoke,
                 .linuxCloudSyncStatus,
                 .linuxCloudSyncPolicyUpdate, .linuxCloudSyncRun:
                return try await handleLinuxAuthRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .health, .catalog, .authBootstrap, .linuxOnboardingSnapshot:
                return try await handleLifecycleRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .configGet, .configUpdate, .linuxOnboardingAction, .linuxOnboardingReset,
                 .textExpansionGet, .textExpansionUpsert, .textExpansionDelete, .textExpansionConsentUpdate,
                 .textExpansionEngineStatus, .textExpansionEngineStart, .textExpansionEngineStop,
                 .textExpansionEngineExpand,
                 .providerCredentialSlotUpsert, .providerCredentialSlotRemove,
                 .providerModelVariantUpsert, .providerModelVariantRemove,
                 .providerModelAliasUpsert, .providerModelAliasRemove,
                 .providerCustomModelUpsert, .providerCustomModelRemove,
                 .providerModelDisplayNameSet, .providerModelDisplayNameClear:
                return try await handleConfigRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
#if os(Linux)
            case .linuxPrivacyInventory, .linuxPrivacyDeletionPreview,
                 .linuxPrivacyDeletionExecute, .linuxPrivacyExport,
                 .linuxPrivacyRetentionStatus, .linuxPrivacyRetentionApply:
                return try await handleLinuxPrivacyRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
#else
            case .linuxPrivacyInventory, .linuxPrivacyDeletionPreview,
                 .linuxPrivacyDeletionExecute, .linuxPrivacyExport,
                 .linuxPrivacyRetentionStatus, .linuxPrivacyRetentionApply:
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Linux privacy RPCs are unavailable on macOS."
                )
#endif
            case .usageRecord, .usageRecent, .usageProjection, .usageRecount,
                 .usageHistory, .usageInsights:
                return try await handleUsageRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .chatThreadList, .chatThreadGet, .chatMessageAppend:
                return try await handleChatRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .inboxList, .inboxGet, .inboxRunsRecent,
                 .inboxConfigGet, .inboxConfigUpdate, .inboxRunNow,
                 .inboxThreadGet, .inboxReply,
                 .inboxPlansList, .inboxPlansGet, .inboxPlansAccept,
                 .inboxPlansUpdateStep, .inboxPlansGrade, .inboxMemoryExport:
                return try await handleInboxRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .proxyRouteLogRecent, .proxyRouteLogClear,
                 .quotaSignalsRecent, .quotaSignalsClear,
                 .perfMeasure:
                return try await handleObservabilityRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .membershipStatus, .membershipCheckoutURL, .membershipPortalURL, .membershipRestore:
                return try await handleMembershipRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .connectorPlaneGet, .connectorConfigUpdate, .connectorAction,
                 .browserToolingGet, .browserToolingUpdate, .browserAction:
                return try await handleToolingRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .computerUseCapabilityStateUpdate,
                 .computerUseSessionGrantReadiness, .computerUseSessionGrantAcquire,
                 .computerUseSessionGrantStatus,
                 .computerUseSessionStart, .computerUseInvoke,
                 .computerUseApprovalPending, .computerUseApprovalRespond,
                 .computerUsePanicHalt, .computerUseAuditExport,
                 .phoneControlPinProvision:
                return try await handleComputerUseRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData,
                    peerPID: peerPID
                )
            case .daemonMediaSessionState, .daemonMediaCallAccept,
                 .daemonMediaCallDecline, .daemonMediaCallEnd,
                 .daemonMediaCapabilityGet, .daemonMediaStatus,
                 .daemonMediaFileOfferList, .daemonMediaFileAccept,
                 .daemonMediaFileDecline, .daemonMediaFileSend:
                return try await handleMediaRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .controllerSummary, .controllerRuntimeSnapshot,
                 .controllerProjectsList, .controllerProjectGet,
                 .controllerProjectUpsert, .controllerProjectDelete,
                 .controllerProjectReassign, .reviewRunRecord,
                 .questionCreate, .questionGet, .questionsList, .questionAnswer,
                 .followupCreate, .followupsList, .followupDone, .followupSnooze, .followupCalendar,
                 .missionCreate, .missionsList, .missionGet, .missionHealth, .missionApprove, .missionCancel,
                 .missionDispatchPacket, .missionRecordResult, .missionAuthorizeRemote,
                 .notificationConfigGet, .notificationConfigUpdate, .notificationHealth, .notificationCommand,
                 .simulatorRun, .simulatorList, .simulatorReplay, .projectionRebuild:
                return try await handleMissionControlRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .clientAttach, .clientClaimControl, .clientDetach:
                return try await handleClientRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .runCreate, .runList, .runGet, .runPoll, .runCancel, .runRetry, .runResume,
             .subscriptionStart, .subscriptionResume, .subscriptionStop,
                 .workspaceExecuteTool, .workspaceToolResult, .approvalRespond:
                return try await handleRunWorkspaceApprovalRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .searchQuery, .searchSQL:
                return try await handleSearchRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .memoryRemember, .memoryRecall, .memoryReviewStatus, .memoryForget, .memoryAuditTrail, .memoryAnalytics:
                return try await handleMemoryRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .codeIndexProject, .codeWatchProject, .codeSearch, .codeContextPack, .codeGetSymbol, .codeFindReferences,
             .codeCallGraph, .codeDiagnostics, .codeIndexStatus, .codeExplore, .codeOpsDiagnostics,
             .codeDatabaseSnapshot, .codeDatabaseRestore:
                return try await handleCodeRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .databaseRecoveryStatus, .databaseRecoveryBundleExport, .databaseRecoveryBundleImport:
                return try await handleDatabaseRecoveryRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .fleetSnapshot, .fleetOrchestratorGet, .fleetOrchestratorSet, .fleetDirectiveRecord:
                return try await handleFleetRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .warFlameRoute, .warFlameDistillList, .warFlameDistillSettle:
                return try await handleWarFlameRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            }
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.error(
                "rpc_request_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: "invalid-request",
                code: error is DecodingError ? BurnBarRPCErrorCode.invalidParams : BurnBarRPCErrorCode.internalError,
                message: error.localizedDescription
            )
        }
    }

    private static func runAcceptLoop(
        server: BurnBarDaemonServer,
        listenerFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        while !Task.isCancelled {
            let clientFileDescriptor = accept(listenerFileDescriptor, nil, nil)
            if clientFileDescriptor == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }

                if code == EBADF || code == EINVAL || Task.isCancelled {
                    break
                }

                logger.error(
                    "accept_failed",
                    metadata: ["errno": "\(code)"]
                )
                continue
            }

            // Round-4 perf sweep: back-pressure. If the gate is at capacity,
            // close the connection immediately rather than spawning an
            // unbounded handler. This prevents FD/memory exhaustion under
            // client bursts; the client's retry is cheap over a local socket.
            guard connectionGate.tryAcquire() else {
                close(clientFileDescriptor)
                logger.warning(
                    "connection_limit_reached",
                    metadata: ["max": "\(connectionGate.maxCount)"]
                )
                continue
            }

            Task.detached(priority: .utility) { [logger] in
                await Self.handleClientConnection(
                    server: server,
                    clientFileDescriptor: clientFileDescriptor,
                    connectionGate: connectionGate,
                    logger: logger
                )
            }
        }

        logger.debug("accept_loop_stopped")
    }

    private static func peerPID(for clientFileDescriptor: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(clientFileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        return result == 0 ? pid : nil
        #elseif os(Linux)
        var credential = BurnBarLinuxPeerSocketCredentials()
        var credentialSize = socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size)
        let result = withUnsafeMutablePointer(to: &credential) { pointer in
            getsockopt(clientFileDescriptor, SOL_SOCKET, SO_PEERCRED, pointer, &credentialSize)
        }
        guard result == 0,
              credentialSize == socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size) else {
            return nil
        }
        return credential.pid
        #else
        return nil
        #endif
    }

    private static func handleClientConnection(
        server: BurnBarDaemonServer,
        clientFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        defer {
            close(clientFileDescriptor)
            connectionGate.release()
        }

        BurnBarUnixDomainSocket.configureNoSigPipe(for: clientFileDescriptor)
        BurnBarUnixDomainSocket.configureIOTimeouts(for: clientFileDescriptor)

        let peerPID = Self.peerPID(for: clientFileDescriptor)

        // RR-3: authenticate the peer's first-party code signature on the live
        // socket BEFORE reading or honoring any RPC. Fail closed — a mismatched,
        // forged, or swapped peer binary never reaches `responseData`, so the
        // bearer token alone can no longer authorize a non-first-party process.
        let peerAuthenticator = server.peerAuthenticator
        let peerCapabilityProfile: BurnBarPeerCapabilityProfile
        do {
            peerCapabilityProfile = try peerAuthenticator.validatePeer(
                socketFD: clientFileDescriptor,
                peerPID: peerPID
            )
        } catch {
            logger.warning(
                "rpc_peer_rejected",
                metadata: [
                    "error": "\(error)",
                    "peer_pid": peerPID.map(String.init) ?? "unknown"
                ]
            )
            // Fail closed, but do not leave the client staring at Cocoa's
            // empty-body decode string. The envelope is unauthorized; the
            // app can then fall back to fleet-snapshot.json.
            let rejection = await server.encodeErrorResponse(
                id: "peer-rejected",
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC peer failed first-party code-signature verification."
            ) + Data([0x0A])
            try? BurnBarUnixDomainSocket.writeAll(rejection, to: clientFileDescriptor)
            return
        }

        do {
            let requestData = try BurnBarUnixDomainSocket.readRequest(
                from: clientFileDescriptor,
                maxBytes: maxRequestBytes
            )
            let responseData = await server.responseData(
                for: requestData,
                peerPID: peerPID,
                peerCapabilityProfile: peerCapabilityProfile
            ) + Data([0x0A])
            try BurnBarUnixDomainSocket.writeAll(responseData, to: clientFileDescriptor)
            logger.debug(
                "rpc_response_sent",
                metadata: ["bytes": "\(responseData.count)"]
            )
        } catch {
            logger.error(
                "client_request_failed",
                metadata: ["error": "\(error)"]
            )
        }
    }
}
