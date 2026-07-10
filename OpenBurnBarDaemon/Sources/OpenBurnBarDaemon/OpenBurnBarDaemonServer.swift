import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

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
    let linuxOnboardingService: BurnBarLinuxOnboardingService
    let subscriptionService: BurnBarSubscriptionService
    let providerExternalAuthService: any BurnBarProviderExternalAuthServing
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    let proxyRouteLogStore: BurnBarProxyRouteLogStore
    let quotaSignalStore: BurnBarQuotaSignalStore
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
    let toolingProxy: BurnBarToolingProxyService
    let computerUseService: ComputerUseService
    #if os(Linux)
    let mediaService: MercuryLinuxMediaSessionController
    #endif
    let missionControlService: any BurnBarMissionControlServing
    let accountService: any BurnBarAccountServing
    let linuxAppCheckService: BurnBarLinuxAppCheckService
    let membershipService: any BurnBarMembershipServing
    let indexedSearch: BurnBarIndexedSearchService?
    let projectCodeMemory: BurnBarProjectCodeMemoryStore?
    let resumeService: BurnBarResumeService?
    private let gatewayServer: BurnBarHTTPGatewayServer?
    private let rateLimiter: BurnBarRateLimiter?
    private var listenerFileDescriptor: Int32?
    private var socketOwnership: BurnBarDaemonSocketOwnership?
    private var boundSocketIdentity: BurnBarSocketIdentity?
    private var acceptLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var oauthRefreshTask: Task<Void, Never>?
    var localAuthVerifiedComputerUseSessions: [String: Date] = [:]

    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        quotaSignalStore: BurnBarQuotaSignalStore? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil,
        missionControlService: (any BurnBarMissionControlServing)? = nil,
        accountService: (any BurnBarAccountServing)? = nil,
        linuxAppCheckService: BurnBarLinuxAppCheckService? = nil,
        membershipService: (any BurnBarMembershipServing)? = nil,
        rateLimiter: BurnBarRateLimiter? = nil,
        peerAuthenticator: BurnBarDaemonPeerAuthenticator = .disabled,
        capabilityProfile: BurnBarPeerCapabilityProfile = .full,
        localAuthProofVerifier: DaemonLocalAuthProofVerifier? = nil,
        phoneControlPinStore: DaemonPhoneKeyPinStore? = nil,
        linuxOnboardingService: BurnBarLinuxOnboardingService? = nil,
        subscriptionService: BurnBarSubscriptionService? = nil,
        providerExternalAuthService: (any BurnBarProviderExternalAuthServing)? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        self.connectionGate = BurnBarConnectionGate()
        self.peerAuthenticator = peerAuthenticator
        self.capabilityProfile = capabilityProfile
        self.localAuthProofVerifier = localAuthProofVerifier
        self.phoneControlPinStore = phoneControlPinStore
        self.linuxOnboardingService = linuxOnboardingService ?? BurnBarLinuxOnboardingService()
        self.subscriptionService = subscriptionService ?? BurnBarSubscriptionService(
            daemonVersion: configuration.daemonVersion
        )
        self.providerExternalAuthService = providerExternalAuthService ?? BurnBarProviderExternalAuthService()

        let resolvedConfigStore = configStore ?? BurnBarConfigStore(
            catalog: configuration.catalog,
            logger: BurnBarDaemonLogger(category: "config-store")
        )
        let resolvedUsageRecorder = usageRecorder ?? BurnBarUsageRecorder(
            logger: BurnBarDaemonLogger(category: "usage-recorder")
        )
        let resolvedProxyRouteLogStore = proxyRouteLogStore ?? BurnBarProxyRouteLogStore(
            logger: BurnBarDaemonLogger(category: "proxy-route-log")
        )
        let resolvedQuotaSignalStore = quotaSignalStore ?? BurnBarQuotaSignalStore(
            logger: BurnBarDaemonLogger(category: "quota-signals")
        )
        let resolvedClientRegistry = clientRegistry ?? BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "client-registry")
        )
        let resolvedRunService = runService ?? BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: resolvedConfigStore,
                logger: BurnBarDaemonLogger(category: "provider-router"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore()
            ),
            usageRecorder: resolvedUsageRecorder,
            clientRegistry: resolvedClientRegistry,
            logger: BurnBarDaemonLogger(category: "run-service")
        )

        self.configStore = resolvedConfigStore
        self.usageRecorder = resolvedUsageRecorder
        self.proxyRouteLogStore = resolvedProxyRouteLogStore
        self.quotaSignalStore = resolvedQuotaSignalStore
        self.clientRegistry = resolvedClientRegistry
        self.runService = resolvedRunService
        self.toolingProxy = BurnBarToolingProxyService(
            connectorPlaneService: resolvedRunService.connectorPlaneService,
            browserToolService: resolvedRunService.browserToolService
        )
        self.computerUseService = ComputerUseService()
        #if os(Linux)
        let mediaLogger = BurnBarDaemonLogger(category: "linux-media")
        self.mediaService = MercuryLinuxMediaSessionController(
            fileTransferService: MercuryLinuxFileTransferFactory.make(logger: mediaLogger),
            downloadDirectoryProvider: {
                MercuryLinuxFileTransferFactory.downloadDirectoryURL()
            },
            logger: mediaLogger
        )
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
        let resolvedAccountService = accountService ?? BurnBarAccountAuthService.production()
        let accountTokenProvider = resolvedAccountService as? any BurnBarAccountTokenProviding
        let appCheckAccountProvider = resolvedAccountService as? any BurnBarAccountAppCheckContextProviding
        self.accountService = resolvedAccountService
        self.linuxAppCheckService = linuxAppCheckService ?? BurnBarLinuxAppCheckService.production(
            accountContext: {
                guard let appCheckAccountProvider else {
                    throw BurnBarLinuxAppCheckError.accountUnavailable
                }
                return try await appCheckAccountProvider.validAppCheckContext()
            },
            accountIdentity: {
                guard let appCheckAccountProvider else { return nil }
                return await appCheckAccountProvider.appCheckIdentitySnapshot()
            }
        )
        self.membershipService = membershipService ?? BurnBarMembershipService(
            cloudClient: EnvironmentBurnBarMembershipCloudClient(
                idTokenProvider: {
                    guard let accountTokenProvider else {
                        throw BurnBarMembershipServiceError.unauthenticated
                    }
                    return try await accountTokenProvider.validIDToken()
                }
            ),
            accountUIDProvider: {
                let status = await resolvedAccountService.status().account
                guard status.state == .signedIn else { return nil }
                return status.uid
            }
        )

        if let path = configuration.indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false,
           FileManager.default.fileExists(atPath: path) {
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
                self.projectCodeMemory = try BurnBarProjectCodeMemoryStore(
                    databasePath: path,
                    logger: BurnBarDaemonLogger(category: "project-code-memory")
                )
            } catch {
                logger.warning(
                    "project_code_memory_init_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
                self.projectCodeMemory = nil
            }
        } else {
            self.indexedSearch = nil
            self.projectCodeMemory = nil
            self.resumeService = nil
        }

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
        #if os(Linux)
        do {
            try await mediaService.start()
        } catch {
            logger.warning(
                "media_channel_start_failed",
                metadata: ["error": "\(error)"]
            )
        }
        #endif
        if configuration.startsMissionControlBackgroundLoops {
            await missionControlService.startBackgroundLoops()
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
        await missionControlService.stopBackgroundLoops()
        #if os(Linux)
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
            case .health, .catalog, .authBootstrap, .linuxOnboardingSnapshot:
                return try await handleLifecycleRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .configGet, .configUpdate, .linuxOnboardingAction, .linuxOnboardingReset,
                 .providerCredentialSlotUpsert, .providerCredentialSlotRemove,
                 .providerExternalAuthStart, .providerExternalAuthStatus, .providerExternalAuthCancel,
                 .providerModelVariantUpsert, .providerModelVariantRemove,
                 .providerModelAliasUpsert, .providerModelAliasRemove,
                 .providerCustomModelUpsert, .providerCustomModelRemove,
                 .providerModelDisplayNameSet, .providerModelDisplayNameClear:
                return try await handleConfigRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .usageRecord, .usageRecent:
                return try await handleUsageRPC(
                    method: method,
                    decoder: decoder,
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
            case .accountStatus, .accountDeviceAuthStart, .accountDeviceAuthPoll,
                 .accountDeviceAuthCancel, .accountSignOut, .linuxAppCheckStatus:
                return try await handleAccountRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .membershipStatus, .membershipCheckoutURL, .membershipRestore:
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
            case .computerUseSessionStart, .computerUseInvoke,
                 .computerUseApprovalPending, .computerUseApprovalRespond,
                 .computerUsePanicHalt, .computerUseAuditExport,
                 .phoneControlPinProvision:
                return try await handleComputerUseRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
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
                 .controllerProjectUpsert, .reviewRunRecord,
                 .questionCreate, .questionGet, .questionsList, .questionAnswer,
                 .followupCreate, .followupsList, .followupDone, .followupSnooze, .followupCalendar,
                 .missionCreate, .missionsList, .missionGet, .missionApprove, .missionCancel,
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
            case .searchQuery:
                return try await handleSearchRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .memoryRemember, .memoryRecall, .memoryForget, .memoryAuditTrail, .memoryAnalytics:
                return try await handleMemoryRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .codeIndexProject, .codeWatchProject, .codeSearch, .codeContextPack, .codeGetSymbol, .codeFindReferences,
                 .codeCallGraph, .codeDiagnostics, .codeIndexStatus, .codeExplore, .codeOpsDiagnostics:
                return try await handleCodeRPC(
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

private struct BurnBarSocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(status: stat) {
        self.device = status.st_dev
        self.inode = status.st_ino
    }
}

private struct BurnBarDaemonSocketOwnership {
    let lockFileDescriptor: Int32

    static func acquire(for socketPath: String) throws -> BurnBarDaemonSocketOwnership {
        let lockPath = socketPath + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1 else {
                throw BurnBarDaemonError.unexpectedExistingItem(lockPath)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw BurnBarDaemonError.daemonAlreadyRunning(socketPath)
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            return BurnBarDaemonSocketOwnership(lockFileDescriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    func release() {
        _ = flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
    }
}

private enum BurnBarUnixDomainSocket {
    static func ensureParentDirectory(for socketPath: String) throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        let directoryURL = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BurnBarDaemonError.failedToCreateParentDirectory(directoryURL.path)
        }
    }

    static func preparePathForBind(at socketPath: String) throws -> Bool {
        var fileStatus = stat()
        let result = lstat(socketPath, &fileStatus)
        if result == -1 {
            if errno == ENOENT {
                return false
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let itemType = fileStatus.st_mode & S_IFMT
        guard itemType == S_IFSOCK else {
            throw BurnBarDaemonError.unexpectedExistingItem(socketPath)
        }

        if try isAcceptingConnections(at: socketPath) {
            throw BurnBarDaemonError.activeSocketAlreadyExists(socketPath)
        }

        let originalIdentity = BurnBarSocketIdentity(status: fileStatus)
        guard try removeSocket(at: socketPath, ifIdentityMatches: originalIdentity) else {
            throw BurnBarDaemonError.socketPathChanged(socketPath)
        }
        return true
    }

    static func socketIdentity(at socketPath: String) throws -> BurnBarSocketIdentity {
        var fileStatus = stat()
        guard lstat(socketPath, &fileStatus) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFSOCK else {
            throw BurnBarDaemonError.unexpectedExistingItem(socketPath)
        }
        return BurnBarSocketIdentity(status: fileStatus)
    }

    static func removeSocket(
        at socketPath: String,
        ifIdentityMatches expectedIdentity: BurnBarSocketIdentity
    ) throws -> Bool {
        var currentStatus = stat()
        guard lstat(socketPath, &currentStatus) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard currentStatus.st_mode & S_IFMT == S_IFSOCK else {
            return false
        }
        guard BurnBarSocketIdentity(status: currentStatus) == expectedIdentity else {
            return false
        }
        guard unlink(socketPath) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func isAcceptingConnections(at socketPath: String) throws -> Bool {
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var address = try makeSocketAddress(for: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(descriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if result == 0 {
            return true
        }
        let code = errno
        if code == ECONNREFUSED || code == ENOENT {
            return false
        }
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }

    static func makeListeningSocket(at socketPath: String) throws -> Int32 {
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fileDescriptor = socket(AF_UNIX, socketType, 0)
        guard fileDescriptor != -1 else {
            throw BurnBarDaemonError.failedToCreateSocket(
                code: errno,
                detail: String(cString: strerror(errno))
            )
        }

        configureNoSigPipe(for: fileDescriptor)

        do {
            var address = try makeSocketAddress(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                    bind(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
                }
            }

            guard bindResult == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToBindSocket(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToListen(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    static func restrictSocketPermissions(at socketPath: String) throws {
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    static func readRequest(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(4_096)

        // 64KB chunks: large requests (mission packets, simulator runs)
        // used to cost one read() syscall per KB.
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let bytesRead = read(fileDescriptor, &chunk, chunk.count)
            if bytesRead == 0 {
                break
            }

            if bytesRead < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }

            buffer.append(contentsOf: chunk.prefix(bytesRead))
            if buffer.count > maxBytes {
                throw BurnBarDaemonError.requestTooLarge(maxBytes)
            }

            if buffer.last == 0x0A {
                break
            }
        }

        while buffer.last == 0x0A || buffer.last == 0x0D {
            buffer.removeLast()
        }

        return buffer
    }

    static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesRemaining = rawBuffer.count
            var writeOffset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: writeOffset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                if bytesWritten < 0 {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                guard bytesWritten > 0 else {
                    throw POSIXError(.EIO)
                }

                bytesRemaining -= bytesWritten
                writeOffset += bytesWritten
            }
        }
    }

    static func configureNoSigPipe(for fileDescriptor: Int32) {
        #if canImport(Darwin)
        var value: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #else
        _ = fileDescriptor
        #endif
    }

    static func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func makeSocketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxPathLength else {
            throw BurnBarDaemonError.socketPathTooLong(socketPath)
        }

        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}
