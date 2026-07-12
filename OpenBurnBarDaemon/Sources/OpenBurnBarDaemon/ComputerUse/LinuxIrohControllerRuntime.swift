#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarKernel

actor LinuxIrohRelayStreamSendGate {
    private let stream: any IrohRelayStream

    init(stream: any IrohRelayStream) {
        self.stream = stream
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        try await stream.send(frame)
    }
}

actor LinuxIrohControllerRuntime {
    enum LifecyclePhase: String, Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
    }

    enum StatusReason: String, Sendable, Equatable {
        case none
        case nativeTransportUnavailable = "native_transport_unavailable"
        case credentialsUnavailable = "credentials_unavailable"
        case credentialsChanged = "credentials_changed"
        case secretStoreUnavailable = "secret_store_unavailable"
        case routeUnavailable = "route_unavailable"
        case routeExpired = "route_expired"
        case routeInvalid = "route_invalid"
        case directoryUnavailable = "directory_unavailable"
        case transportUnavailable = "transport_unavailable"
        case stoppedByOwner = "stopped_by_owner"
    }

    struct RuntimeStatus: Sendable, Equatable {
        let phase: LifecyclePhase
        let reason: StatusReason
        let changedAt: Date
        let retryAt: Date?
    }

    private enum Lifecycle: Sendable, Equatable {
        case stopped(epoch: UInt64)
        case starting(epoch: UInt64)
        case running(epoch: UInt64)
        case stopping(epoch: UInt64)

        var epoch: UInt64 {
            switch self {
            case .stopped(let epoch), .starting(let epoch), .running(let epoch), .stopping(let epoch): epoch
            }
        }

        var phase: LifecyclePhase {
            switch self {
            case .stopped: .stopped
            case .starting: .starting
            case .running: .running
            case .stopping: .stopping
            }
        }
    }
    struct SessionRoute: Sendable, Equatable {
        let uid: String
        let connectionID: String
        let sourceDeviceID: String
        let transportNodeID: String
        let authorityPeerNodeID: String
        let generation: Int64
        let accountGeneration: UInt64
        let expiresAt: Date
    }

    enum RuntimeError: Error, Equatable, Sendable {
        case nativeTransportUnavailable
        case identityUnavailable
        case credentialsUnavailable
        case routeUnavailable
        case routeExpired
        case streamUnavailable
        case frameRejected
        case handlersUnavailable
    }

    typealias CredentialProvider = LinuxIrohControllerCredentialProvider
    typealias GrantHandler = @Sendable (
        HermesRealtimeRelayAgentGrantRequest,
        String
    ) async throws -> Void
    typealias ApprovalHandler = @Sendable (
        String,
        HermesRealtimeRelayApprovalResponse,
        String,
        Int64
    ) async throws -> Void
    typealias PanicHandler = @Sendable (
        [String],
        HermesRealtimeRelayInputIntent,
        String,
        String
    ) async throws -> Void
    typealias SessionRevoker = @Sendable (_ sessionIDs: [String], _ reason: String) async -> Void
    typealias RouteEndedHandler = @Sendable (_ route: LinuxIrohControllerRoute, _ reason: String) async -> Void
    typealias MediaHandler = @Sendable (
        HermesRealtimeRelayFrame,
        String,
        @escaping MercuryLinuxMediaReplySender
    ) async -> Void
    typealias AuthorityReadiness = @Sendable (
        _ sourceDeviceID: String,
        _ authorityPeerNodeID: String
    ) async -> Bool

    private struct Handlers: Sendable {
        let grant: GrantHandler
        let approval: ApprovalHandler
        let panic: PanicHandler
        let revokeSessions: SessionRevoker
        let routeEnded: RouteEndedHandler
        let media: MediaHandler
    }

    private struct LiveStream: Sendable {
        let id: UUID
        let stream: any IrohRelayStream
        let sendGate: LinuxIrohRelayStreamSendGate
        let routeGeneration: Int64
    }

    private let transport: any IrohRelayTransport
    private let directory: any LinuxIrohControllerDirectoryServing
    private let identityStore: any LinuxIrohHostIdentityProviding
    private let credentialProvider: CredentialProvider
    private let authorityReadiness: AuthorityReadiness
    private let endpointSecretBox: LinuxIrohEndpointSecretBox?
    private let logger: BurnBarDaemonLogger
    private let refreshIntervalNanoseconds: UInt64
    private let acceptTimeout: TimeInterval

    private var handlers: Handlers?
    private var hostIdentity: LinuxIrohHostIdentity?
    private var endpointIdentity: IrohEndpointIdentity?
    private var uid: String?
    private var connectionID: String?
    private var accountGeneration: UInt64?
    private var route: LinuxIrohControllerRoute?
    private var liveStreams: [String: LiveStream] = [:]
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var sessions: [String: SessionRoute] = [:]
    private var acceptTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var routeExpiryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var terminalInvalidationTask: Task<Void, Never>?
    private var terminalInvalidationID: UUID?
    private var routeRefreshSequence: UInt64 = 0
    private var lifecycle: Lifecycle = .stopped(epoch: 0)
    private var runtimeStatus = RuntimeStatus(phase: .stopped, reason: .none, changedAt: Date(), retryAt: nil)
    private var operational = false
    private var stopping = false

    init(
        transport: any IrohRelayTransport,
        directory: any LinuxIrohControllerDirectoryServing,
        identityStore: any LinuxIrohHostIdentityProviding = LinuxIrohHostIdentityStore(),
        credentialProvider: @escaping CredentialProvider,
        authorityReadiness: @escaping AuthorityReadiness,
        endpointSecretBox: LinuxIrohEndpointSecretBox? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-iroh-controller"),
        refreshIntervalNanoseconds: UInt64 = 60_000_000_000,
        acceptTimeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.directory = directory
        self.identityStore = identityStore
        self.credentialProvider = credentialProvider
        self.authorityReadiness = authorityReadiness
        self.endpointSecretBox = endpointSecretBox
        self.logger = logger
        self.refreshIntervalNanoseconds = refreshIntervalNanoseconds
        self.acceptTimeout = acceptTimeout
    }

    static func production(
        credentialProvider: @escaping LinuxIrohControllerCredentialProvider,
        phoneControlPinStore: DaemonPhoneKeyPinStore,
        authorityHealth: @escaping @Sendable () async -> Bool,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-iroh-controller")
    ) -> LinuxIrohControllerRuntime? {
        guard let backend = OpenBurnBarIrohFFIBackendFactory.make() else { return nil }
        let directory = LinuxIrohControllerDirectoryClient(credentials: credentialProvider)
        let secretBox = LinuxIrohEndpointSecretBox()
        let transport = IrohXcframeworkTransport(
            backend: backend,
            secretProvider: { try secretBox.require() }
        )
        return LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            credentialProvider: credentialProvider,
            authorityReadiness: { sourceDeviceID, authorityPeerNodeID in
                guard await authorityHealth() else { return false }
                let sourceKey: PhoneControlVerifyingKey
                let authorityKey: PhoneControlVerifyingKey
                guard case .pinned(let source) = phoneControlPinStore.pinnedKey(deviceId: sourceDeviceID),
                      case .pinned(let authority) = phoneControlPinStore.pinnedKey(deviceId: authorityPeerNodeID) else {
                    return false
                }
                sourceKey = source
                authorityKey = authority
                return sourceKey.kind == authorityKey.kind
                    && sourceKey.publicKeyRepresentation == authorityKey.publicKeyRepresentation
            },
            endpointSecretBox: secretBox,
            logger: logger
        )
    }

    func installHandlers(
        grant: @escaping GrantHandler,
        approval: @escaping ApprovalHandler,
        panic: @escaping PanicHandler,
        revokeSessions: @escaping SessionRevoker,
        routeEnded: @escaping RouteEndedHandler = { _, _ in },
        media: @escaping MediaHandler
    ) {
        handlers = Handlers(
            grant: grant,
            approval: approval,
            panic: panic,
            revokeSessions: revokeSessions,
            routeEnded: routeEnded,
            media: media
        )
    }

    func start() async throws {
        switch lifecycle {
        case .running, .starting:
            return
        case .stopping:
            throw CancellationError()
        case .stopped:
            break
        }
        guard handlers != nil else { throw RuntimeError.handlersUnavailable }
        let epoch = lifecycle.epoch &+ 1
        lifecycle = .starting(epoch: epoch)
        setStatus(.starting, reason: .none)
        stopping = false
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStart(epoch: epoch)
        }
        startupTask = task
        do {
            try await task.value
        } catch {
            if case .starting(epoch) = lifecycle {
                operational = false
                clearLocalState()
                lifecycle = .stopped(epoch: epoch)
            }
            if lifecycle.epoch == epoch { startupTask = nil }
            throw error
        }
        if lifecycle.epoch == epoch { startupTask = nil }
    }

    private func performStart(epoch: UInt64) async throws {
        let identity: LinuxIrohHostIdentity
        do {
            identity = try identityStore.loadOrCreate()
        } catch {
            setStatus(.stopped, reason: .secretStoreUnavailable)
            throw RuntimeError.identityUnavailable
        }
        try requireLifecycle(.starting(epoch: epoch))
        hostIdentity = identity
        endpointSecretBox?.publish(identity.endpointSecret)

        let credentials: LinuxIrohControllerCredentialContext
        do {
            credentials = try await credentialProvider()
        } catch {
            clearLocalState()
            setStatus(.stopped, reason: .credentialsUnavailable)
            throw RuntimeError.credentialsUnavailable
        }
        try requireLifecycle(.starting(epoch: epoch))
        let connectionID = Self.connectionID(deviceID: credentials.deviceID)
        let endpoint: IrohEndpointIdentity
        do {
            endpoint = try await retrying(epoch: epoch, expected: .starting(epoch: epoch)) {
                try await self.transport.start()
            }
        } catch {
            clearLocalState()
            setStatus(.stopped, reason: .transportUnavailable)
            throw error
        }
        try requireLifecycle(.starting(epoch: epoch))
        endpointIdentity = endpoint
        uid = credentials.uid
        self.connectionID = connectionID
        accountGeneration = credentials.sessionGeneration

        var hostRecordPublicationAttempted = false
        do {
            try await retrying(epoch: epoch, expected: .starting(epoch: epoch)) {
                try await self.directory.publishHostPublicKey(identity.pairingKeypair)
            }
            try requireLifecycle(.starting(epoch: epoch))
            hostRecordPublicationAttempted = true
            try await retrying(epoch: epoch, expected: .starting(epoch: epoch)) {
                try await self.publishRecord(now: Date())
            }
        } catch {
            if hostRecordPublicationAttempted {
                await revokeHostRecordWithRetry(connectionID)
            }
            await transport.shutdown()
            clearLocalState()
            setStatus(.stopped, reason: .directoryUnavailable)
            throw error
        }
        try requireLifecycle(.starting(epoch: epoch))
        operational = true
        lifecycle = .running(epoch: epoch)
        setStatus(.running, reason: .routeUnavailable)
        await refreshRoute(epoch: epoch)
        try requireLifecycle(.running(epoch: epoch))
        acceptTask = Task { [weak self] in await self?.runAcceptLoop(epoch: epoch) }
        refreshTask = Task { [weak self] in await self?.runRefreshLoop(epoch: epoch) }
        logger.notice(
            "linux_iroh_controller_started",
            metadata: ["connection_id": connectionID, "node_id": endpoint.nodeId]
        )
    }

    func stop(teardownCredentials: LinuxIrohControllerCredentialContext? = nil) async {
        if let terminalInvalidationTask {
            terminalInvalidationTask.cancel()
            _ = await terminalInvalidationTask.result
        }
        if case .stopped = lifecycle { return }
        let epoch = lifecycle.epoch &+ 1
        lifecycle = .stopping(epoch: epoch)
        setStatus(.stopping, reason: .stoppedByOwner)
        stopping = true
        operational = false
        let connectionIDToRevoke = connectionID
        let startupTask = self.startupTask
        let acceptTask = self.acceptTask
        let refreshTask = self.refreshTask
        let routeExpiryTask = self.routeExpiryTask
        self.acceptTask = nil
        self.refreshTask = nil
        self.routeExpiryTask = nil
        self.startupTask = nil
        startupTask?.cancel()
        acceptTask?.cancel()
        refreshTask?.cancel()
        routeExpiryTask?.cancel()
        _ = await startupTask?.result

        let streams = liveStreams.values.map(\.stream)
        liveStreams.removeAll()
        let streamTasks = Array(self.streamTasks.values)
        self.streamTasks.removeAll()
        let sessionIDs = Array(sessions.keys)
        sessions.removeAll()
        if let handlers, sessionIDs.isEmpty == false {
            await handlers.revokeSessions(sessionIDs, "controller_runtime_stopped")
        }
        if let route, let handlers {
            await handlers.routeEnded(route, "controller_runtime_stopped")
        }
        for stream in streams { await stream.close() }
        streamTasks.forEach { $0.cancel() }
        for task in streamTasks { _ = await task.result }
        await transport.shutdown()
        _ = await acceptTask?.result
        _ = await refreshTask?.result
        _ = await routeExpiryTask?.result
        if let connectionIDToRevoke {
            await revokeHostRecordWithRetry(
                connectionIDToRevoke,
                credentials: teardownCredentials
            )
        }
        clearLocalState()
        stopping = false
        lifecycle = .stopped(epoch: epoch)
        setStatus(.stopped, reason: .stoppedByOwner)
    }

    func status() -> RuntimeStatus { runtimeStatus }

    func refreshNow() async {
        guard case .running(let epoch) = lifecycle else { return }
        await refresh(epoch: epoch)
    }

    func isReady(now: Date = Date()) async -> Bool {
        guard operational,
              let admittedRoute = route,
              admittedRoute.expiresAt > now,
              admittedRoute.uid == uid,
              admittedRoute.connectionID == connectionID,
              admittedRoute.accountGeneration == accountGeneration,
              let stream = liveStreams[admittedRoute.transportNodeID],
              stream.routeGeneration == admittedRoute.generation else {
            return false
        }
        let credentials: LinuxIrohControllerCredentialContext
        do {
            credentials = try await credentialProvider()
        } catch {
            scheduleTerminalInvalidation(
                reason: "credentials_unavailable",
                statusReason: .credentialsUnavailable
            )
            return false
        }
        guard operational,
              route == admittedRoute,
              credentials.uid == admittedRoute.uid,
              credentials.sessionGeneration == admittedRoute.accountGeneration,
              Self.connectionID(deviceID: credentials.deviceID) == admittedRoute.connectionID else {
            scheduleTerminalInvalidation(reason: "credentials_changed", statusReason: .credentialsChanged)
            return false
        }
        guard await authorityReadiness(
            admittedRoute.sourceDeviceID,
            admittedRoute.authorityPeerNodeID
        ) else {
            return false
        }
        return operational && route == admittedRoute && admittedRoute.expiresAt > Date()
    }

    func acquisitionMetadata(
        requirement: BurnBarComputerUseRunRequirement,
        request: ComputerUseSessionStartRequest,
        now: Date = Date()
    ) async throws -> ComputerUseSessionGrantBroker.AcquisitionMetadata {
        guard await isReady(now: now), let route else { throw RuntimeError.routeUnavailable }
        guard request.mode == ComputerUseMode.browser.rawValue else { throw RuntimeError.frameRejected }
        return ComputerUseSessionGrantBroker.AcquisitionMetadata(
            uid: route.uid,
            connectionID: route.connectionID,
            transportPeerNodeID: route.transportNodeID,
            authorityPeerNodeID: route.authorityPeerNodeID,
            sourceDeviceID: route.sourceDeviceID,
            runtimeID: .hermes,
            threadID: requirement.sessionID.rawValue,
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot],
            routeGeneration: route.generation,
            routeExpiresAt: route.expiresAt,
            accountGeneration: route.accountGeneration
        )
    }

    func publish(to transportPeerNodeID: String, frame: HermesRealtimeRelayFrame) async throws {
        let peer = transportPeerNodeID.lowercased()
        guard await isReady(),
              operational,
              let route,
              route.transportNodeID == peer,
              route.expiresAt > Date(),
              frame.uid == route.uid,
              frame.connectionId == route.connectionID,
              let live = liveStreams[peer],
              live.routeGeneration == route.generation else {
            throw RuntimeError.streamUnavailable
        }
        try await live.sendGate.send(frame)
    }

    func bindSession(
        _ sessionID: String,
        metadata: ComputerUseSessionGrantBroker.AcquisitionMetadata
    ) async throws {
        let reservedRoute = SessionRoute(metadata)
        guard await isReady(),
              let route else {
            throw RuntimeError.routeUnavailable
        }
        let currentRoute = SessionRoute(route)
        guard reservedRoute.matchesLeasePrincipalAndGeneration(currentRoute),
              currentRoute.expiresAt >= reservedRoute.expiresAt else {
            throw RuntimeError.routeUnavailable
        }
        sessions[sessionID] = currentRoute
    }

    func unbindSession(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    func authorizesSessionAuthority(
        sessionID: String,
        authorityPeerNodeID: String,
        transportPeerNodeID: String,
        routeGeneration: Int64,
        now: Date = Date()
    ) async -> Bool {
        guard await isReady(now: now),
              let route,
              route.authorityPeerNodeID == authorityPeerNodeID,
              route.transportNodeID == transportPeerNodeID.lowercased(),
              route.generation == routeGeneration,
              sessions[sessionID] == SessionRoute(route) else {
            return false
        }
        return true
    }

    func publishApproval(_ request: HermesRealtimeRelayApprovalRequest) async throws {
        guard let route = sessions[request.sessionId], route.expiresAt > Date() else {
            throw RuntimeError.routeUnavailable
        }
        let frame = HermesRealtimeRelayFrame(
            type: .controlApprovalRequest,
            uid: route.uid,
            connectionId: route.connectionID,
            requestId: request.approvalId,
            runtime: AssistantRuntimeID.hermes.rawValue,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.approval",
                sessionId: request.sessionId,
                approvalRequest: request
            )
        )
        try await publish(to: route.transportNodeID, frame: frame)
    }

    private func runAcceptLoop(epoch: UInt64) async {
        var consecutiveFailures = 0
        while Task.isCancelled == false, lifecycle == .running(epoch: epoch) {
            do {
                let stream = try await transport.accept(timeout: acceptTimeout)
                try requireLifecycle(.running(epoch: epoch))
                consecutiveFailures = 0
                await accept(stream, epoch: epoch)
            } catch is CancellationError {
                return
            } catch let error as IrohRelayTransportError where error == .timedOut {
                continue
            } catch {
                if lifecycle != .running(epoch: epoch) { return }
                consecutiveFailures = min(consecutiveFailures + 1, 5)
                logger.warning("linux_iroh_accept_failed", metadata: ["error": "transport"])
                let delay = retryDelay(attempt: consecutiveFailures, epoch: epoch)
                setStatus(.running, reason: .transportUnavailable, retryAt: Date().addingTimeInterval(delay))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func accept(_ stream: any IrohRelayStream, epoch: UInt64) async {
        guard let remote = stream.remotePeerNodeId?.lowercased(),
              lifecycle == .running(epoch: epoch),
              let route,
              route.transportNodeID == remote,
              route.expiresAt > Date() else {
            await stream.close()
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serveControlStream(stream, id: id, admittedRoute: route, epoch: epoch)
        }
        streamTasks[id] = task
    }

    private func serveControlStream(
        _ stream: any IrohRelayStream,
        id: UUID,
        admittedRoute: LinuxIrohControllerRoute,
        epoch: UInt64
    ) async {
        defer { streamTasks.removeValue(forKey: id) }
        do {
            guard let first = try await stream.receive(),
                  first.type == .mediaClassify,
                  first.media?.streamClass == "media.control",
                  first.uid == admittedRoute.uid,
                  first.connectionId == admittedRoute.connectionID else {
                throw RuntimeError.frameRejected
            }
            guard lifecycle == .running(epoch: epoch),
                  let currentRoute = route,
                  currentRoute == admittedRoute,
                  currentRoute.expiresAt > Date(),
                  stream.remotePeerNodeId?.lowercased() == currentRoute.transportNodeID else {
                throw RuntimeError.routeUnavailable
            }
            let gate = LinuxIrohRelayStreamSendGate(stream: stream)
            if let previous = liveStreams[currentRoute.transportNodeID] {
                await previous.stream.close()
            }
            guard lifecycle == .running(epoch: epoch), route == currentRoute else {
                throw RuntimeError.routeUnavailable
            }
            liveStreams[currentRoute.transportNodeID] = LiveStream(
                id: id,
                stream: stream,
                sendGate: gate,
                routeGeneration: currentRoute.generation
            )
            while let frame = try await stream.receive() {
                guard lifecycle == .running(epoch: epoch),
                      let activeRoute = self.route,
                      activeRoute.hasSamePrincipal(as: admittedRoute),
                      frame.uid == activeRoute.uid,
                      frame.connectionId == activeRoute.connectionID,
                      liveStreams[activeRoute.transportNodeID]?.id == id else {
                    throw RuntimeError.frameRejected
                }
                try await routeFrame(frame, route: activeRoute, gate: gate, epoch: epoch)
            }
        } catch {
            logger.warning(
                "linux_iroh_control_stream_closed",
                metadata: ["peer_node_id": admittedRoute.transportNodeID, "reason": "receive_failed"]
            )
        }
        if liveStreams[admittedRoute.transportNodeID]?.id == id {
            liveStreams.removeValue(forKey: admittedRoute.transportNodeID)
            if let current = route, current.hasSamePrincipal(as: admittedRoute) {
                await revokeSessions(boundTo: current, reason: "controller_stream_closed")
                await handlers?.routeEnded(current, "controller_stream_closed")
            }
        }
        await stream.close()
    }

    private func routeFrame(
        _ frame: HermesRealtimeRelayFrame,
        route: LinuxIrohControllerRoute,
        gate: LinuxIrohRelayStreamSendGate,
        epoch: UInt64
    ) async throws {
        guard let handlers,
              lifecycle == .running(epoch: epoch),
              operational,
              route.expiresAt > Date(),
              route.uid == uid,
              route.connectionID == connectionID,
              route.accountGeneration == accountGeneration,
              self.route == route,
              liveStreams[route.transportNodeID]?.routeGeneration == route.generation else {
            throw RuntimeError.routeExpired
        }
        let credentials = try await credentialProvider()
        guard lifecycle == .running(epoch: epoch),
              self.route == route,
              credentials.uid == route.uid,
              credentials.sessionGeneration == route.accountGeneration,
              Self.connectionID(deviceID: credentials.deviceID) == route.connectionID else {
            scheduleTerminalInvalidation(reason: "credentials_changed", statusReason: .credentialsChanged)
            throw RuntimeError.credentialsUnavailable
        }
        let reply: MercuryLinuxMediaReplySender = { outbound in try await gate.send(outbound) }
        switch frame.type {
        case .controlAgentGrantRequest:
            guard let request = frame.control?.agentGrantRequest,
                  request.authority.peerNodeId == route.authorityPeerNodeID,
                  request.sourceDeviceId == route.sourceDeviceID else {
                throw RuntimeError.frameRejected
            }
            try await handlers.grant(request, route.transportNodeID)
        case .controlApprovalResponse:
            guard let sessionID = frame.control?.sessionId,
                  let response = frame.control?.approvalResponse,
                  response.respondedBy == route.authorityPeerNodeID,
                  response.authority?.peerNodeId == route.authorityPeerNodeID,
                  sessions[sessionID] == SessionRoute(route) else {
                throw RuntimeError.frameRejected
            }
            try await handlers.approval(sessionID, response, route.transportNodeID, route.generation)
        case .controlInputIntent:
            guard frame.control?.sessionId != nil,
                  let intent = frame.control?.inputIntent,
                  intent.kind == .panic,
                  intent.authority.peerNodeId == route.authorityPeerNodeID,
                  sessions.values.contains(SessionRoute(route)) else {
                throw RuntimeError.frameRejected
            }
            let sessionIDs = sessions.compactMap { $0.value == SessionRoute(route) ? $0.key : nil }
            try await handlers.panic(
                sessionIDs,
                intent,
                route.transportNodeID,
                route.authorityPeerNodeID
            )
        case .mediaBlobAdvertise, .mediaBlobAck, .mediaMirrorRequest, .mediaMirrorAck,
             .mediaMirrorStop, .mediaMirrorDisplaySelect, .mediaPresenceHeartbeat,
             .mediaLongTermReferenceAck, .mediaCallInvite, .mediaCallAck, .mediaStreamFrame:
            await handlers.media(frame, route.transportNodeID, reply)
        case .mediaClassify, .controlClassify:
            break
        default:
            throw RuntimeError.frameRejected
        }
    }

    private func runRefreshLoop(epoch: UInt64) async {
        while Task.isCancelled == false, lifecycle == .running(epoch: epoch) {
            do {
                try await Task.sleep(nanoseconds: refreshIntervalNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false, lifecycle == .running(epoch: epoch) else { return }
            await refresh(epoch: epoch)
        }
    }

    private func refresh(epoch: UInt64) async {
        let credentials: LinuxIrohControllerCredentialContext
        do {
            credentials = try await credentialProvider()
        } catch {
            guard lifecycle == .running(epoch: epoch) else { return }
            scheduleTerminalInvalidation(
                reason: "credentials_unavailable",
                statusReason: .credentialsUnavailable
            )
            return
        }
        do {
            try requireLifecycle(.running(epoch: epoch))
            guard credentials.uid == uid,
                  credentials.sessionGeneration == accountGeneration,
                  Self.connectionID(deviceID: credentials.deviceID) == connectionID else {
                scheduleTerminalInvalidation(reason: "credentials_changed", statusReason: .credentialsChanged)
                return
            }
            try await retrying(epoch: epoch, expected: .running(epoch: epoch)) {
                try await self.publishRecord(now: Date())
            }
            await refreshRoute(epoch: epoch)
        } catch {
            if lifecycle == .running(epoch: epoch) {
                setStatus(.running, reason: .directoryUnavailable)
            }
        }
    }

    private func publishRecord(now: Date) async throws {
        guard let uid, let connectionID, let endpointIdentity, let hostIdentity else {
            throw RuntimeError.identityUnavailable
        }
        let record = try IrohPairingSignature.sign(
            uid: uid,
            connectionId: connectionID,
            nodeId: endpointIdentity.nodeId,
            relayURL: endpointIdentity.relayURL,
            directAddresses: endpointIdentity.directAddresses,
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1_000),
            with: hostIdentity.pairingKeypair.signingKey
        )
        try await directory.publishHostRecord(record)
    }

    private func refreshRoute(epoch: UInt64) async {
        guard let connectionID else { return }
        routeRefreshSequence &+= 1
        let refreshSequence = routeRefreshSequence
        do {
            let resolved = try await retrying(epoch: epoch, expected: .running(epoch: epoch)) {
                try await self.directory.resolveActiveRoute(connectionID: connectionID)
            }
            try requireLifecycle(.running(epoch: epoch))
            guard refreshSequence == routeRefreshSequence else { return }
            guard let next = resolved else {
                if let current = route {
                    await invalidateRoute(current, reason: "controller_route_unavailable")
                    route = nil
                }
                setStatus(.running, reason: .routeUnavailable)
                return
            }
            guard next.uid == uid, next.accountGeneration == accountGeneration else {
                throw RuntimeError.routeUnavailable
            }
            if let current = route {
                if next == current {
                    scheduleRouteExpiry(next, epoch: epoch)
                    setStatus(.running, reason: .none)
                    return
                }
                let isLeaseRenewal = next.generation == current.generation
                    && next.registeredAt == current.registeredAt
                let isAuthorityReplacement = next.generation > current.generation
                    && next.registeredAt > current.registeredAt
                guard next.hasSamePrincipal(as: current),
                      isLeaseRenewal || isAuthorityReplacement,
                      next.expiresAt > current.expiresAt else {
                    await invalidateRoute(current, reason: "controller_route_invalid")
                    route = nil
                    setStatus(.running, reason: .routeInvalid)
                    return
                }
                if isLeaseRenewal {
                    migrateLease(from: current, to: next)
                } else {
                    // A generation increment is a fresh authority bootstrap,
                    // so privileged work from the old route cannot carry over.
                    await invalidateRoute(current, reason: "controller_route_replaced")
                }
            }
            route = next
            scheduleRouteExpiry(next, epoch: epoch)
            setStatus(.running, reason: .none)
        } catch {
            guard lifecycle == .running(epoch: epoch),
                  refreshSequence == routeRefreshSequence else { return }
            if route == nil {
                setStatus(.running, reason: .routeUnavailable)
            } else {
                setStatus(.running, reason: .directoryUnavailable)
            }
        }
    }

    private func invalidateRuntime(
        expectedRunningEpoch: UInt64,
        reason: String,
        statusReason: StatusReason
    ) async {
        guard lifecycle == .running(epoch: expectedRunningEpoch) else { return }
        let epoch = expectedRunningEpoch &+ 1
        lifecycle = .stopping(epoch: epoch)
        setStatus(.stopping, reason: statusReason)
        operational = false
        let acceptTask = acceptTask
        let refreshTask = refreshTask
        let routeExpiryTask = routeExpiryTask
        acceptTask?.cancel()
        refreshTask?.cancel()
        routeExpiryTask?.cancel()
        self.acceptTask = nil
        self.refreshTask = nil
        self.routeExpiryTask = nil
        if let route { await invalidateRoute(route, reason: reason) }
        let remainingSessionIDs = Array(sessions.keys)
        sessions.removeAll()
        if remainingSessionIDs.isEmpty == false, let handlers {
            await handlers.revokeSessions(remainingSessionIDs, reason)
        }
        let remainingStreams = liveStreams.values.map(\.stream)
        liveStreams.removeAll()
        for stream in remainingStreams { await stream.close() }
        let tasks = Array(streamTasks.values)
        streamTasks.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        await transport.shutdown()
        _ = await acceptTask?.result
        _ = await refreshTask?.result
        _ = await routeExpiryTask?.result
        if let connectionID { await revokeHostRecordWithRetry(connectionID) }
        guard lifecycle == .stopping(epoch: epoch) else { return }
        clearLocalState()
        lifecycle = .stopped(epoch: epoch)
        setStatus(.stopped, reason: statusReason)
    }

    private func scheduleTerminalInvalidation(reason: String, statusReason: StatusReason) {
        guard terminalInvalidationTask == nil,
              case .running(let expectedRunningEpoch) = lifecycle else {
            return
        }
        let invalidationID = UUID()
        terminalInvalidationID = invalidationID
        terminalInvalidationTask = Task { [weak self] in
            await self?.invalidateRuntime(
                expectedRunningEpoch: expectedRunningEpoch,
                reason: reason,
                statusReason: statusReason
            )
            await self?.finishTerminalInvalidation(id: invalidationID)
        }
    }

    private func finishTerminalInvalidation(id: UUID) {
        guard terminalInvalidationID == id else { return }
        terminalInvalidationID = nil
        terminalInvalidationTask = nil
    }

    private func invalidateRoute(_ route: LinuxIrohControllerRoute, reason: String) async {
        if self.route == route {
            routeExpiryTask?.cancel()
            routeExpiryTask = nil
        }
        if let live = liveStreams.removeValue(forKey: route.transportNodeID) {
            await live.stream.close()
        }
        await revokeSessions(boundTo: route, reason: reason)
        await handlers?.routeEnded(route, reason)
    }

    private func scheduleRouteExpiry(_ route: LinuxIrohControllerRoute, epoch: UInt64) {
        routeExpiryTask?.cancel()
        let delay = min(max(0, route.expiresAt.timeIntervalSinceNow), 15 * 60)
        routeExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.expireRouteIfCurrent(route, epoch: epoch)
        }
    }

    private func expireRouteIfCurrent(_ expected: LinuxIrohControllerRoute, epoch: UInt64) async {
        guard lifecycle == .running(epoch: epoch), route == expected, expected.expiresAt <= Date() else { return }
        await invalidateRoute(expected, reason: "controller_route_expired")
        route = nil
        setStatus(.running, reason: .routeExpired)
    }

    private func migrateLease(from old: LinuxIrohControllerRoute, to renewed: LinuxIrohControllerRoute) {
        if let live = liveStreams[old.transportNodeID], live.routeGeneration == old.generation {
            liveStreams[old.transportNodeID] = LiveStream(
                id: live.id,
                stream: live.stream,
                sendGate: live.sendGate,
                routeGeneration: renewed.generation
            )
        }
        let oldBinding = SessionRoute(old)
        let renewedBinding = SessionRoute(renewed)
        for (sessionID, binding) in sessions where binding == oldBinding {
            sessions[sessionID] = renewedBinding
        }
    }

    private func revokeSessions(boundTo route: LinuxIrohControllerRoute, reason: String) async {
        let binding = SessionRoute(route)
        let sessionIDs = sessions.compactMap { $0.value == binding ? $0.key : nil }
        sessionIDs.forEach { sessions.removeValue(forKey: $0) }
        if sessionIDs.isEmpty == false, let handlers {
            await handlers.revokeSessions(sessionIDs, reason)
        }
    }

    private func clearLocalState() {
        routeRefreshSequence &+= 1
        hostIdentity = nil
        endpointIdentity = nil
        uid = nil
        connectionID = nil
        accountGeneration = nil
        route = nil
        routeExpiryTask?.cancel()
        routeExpiryTask = nil
        liveStreams.removeAll()
        sessions.removeAll()
        operational = false
        endpointSecretBox?.clear()
    }

    private func setStatus(
        _ phase: LifecyclePhase,
        reason: StatusReason,
        retryAt: Date? = nil
    ) {
        runtimeStatus = RuntimeStatus(phase: phase, reason: reason, changedAt: Date(), retryAt: retryAt)
    }

    private func revokeHostRecordWithRetry(
        _ connectionID: String,
        credentials: LinuxIrohControllerCredentialContext? = nil,
        maximumAttempts: Int = 4
    ) async {
        var attempt = 0
        while attempt < maximumAttempts {
            do {
                if let credentials,
                   let scopedDirectory = directory as? any LinuxIrohControllerCredentialScopedRevoking {
                    try await scopedDirectory.revokeHostRecord(
                        connectionID: connectionID,
                        credentials: credentials
                    )
                } else {
                    try await directory.revokeHostRecord(connectionID: connectionID)
                }
                return
            } catch {
                attempt += 1
                guard attempt < maximumAttempts, Self.isRetryable(error) else {
                    logger.warning(
                        "linux_iroh_controller_revoke_failed",
                        metadata: ["connection_id": connectionID]
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 50_000_000)
            }
        }
    }

    private func requireLifecycle(_ expected: Lifecycle) throws {
        try Task.checkCancellation()
        guard lifecycle == expected else { throw CancellationError() }
    }

    private func retrying<T: Sendable>(
        epoch: UInt64,
        expected: Lifecycle,
        maximumAttempts: Int = 4,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try requireLifecycle(expected)
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < maximumAttempts, Self.isRetryable(error) else { throw error }
                let delay = retryDelay(attempt: attempt, epoch: epoch)
                setStatus(
                    expected.phase,
                    reason: .directoryUnavailable,
                    retryAt: Date().addingTimeInterval(delay)
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func retryDelay(attempt: Int, epoch: UInt64) -> TimeInterval {
        let capped = min(max(attempt, 1), 5)
        let base = min(4.0, 0.25 * pow(2.0, Double(capped - 1)))
        let bucket = Double((epoch &+ UInt64(capped * 17)) % 21) / 100.0
        return base * (0.9 + bucket)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let directoryError = error as? LinuxIrohControllerDirectoryError else { return true }
        switch directoryError {
        case .transportFailure:
            return true
        case .rejected(let status):
            return status == 429 || status >= 500
        default:
            return false
        }
    }

    private static func connectionID(deviceID: String) -> String {
        "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
    }
}

private extension LinuxIrohControllerRoute {
    func hasSamePrincipal(as other: LinuxIrohControllerRoute) -> Bool {
        uid == other.uid
            && connectionID == other.connectionID
            && sourceDeviceID == other.sourceDeviceID
            && transportNodeID == other.transportNodeID
            && authorityPeerNodeID == other.authorityPeerNodeID
            && accountGeneration == other.accountGeneration
    }
}

private extension LinuxIrohControllerRuntime.SessionRoute {
    func matchesLeasePrincipalAndGeneration(_ other: Self) -> Bool {
        uid == other.uid
            && connectionID == other.connectionID
            && sourceDeviceID == other.sourceDeviceID
            && transportNodeID == other.transportNodeID
            && authorityPeerNodeID == other.authorityPeerNodeID
            && generation == other.generation
            && accountGeneration == other.accountGeneration
    }

    init(_ route: LinuxIrohControllerRoute) {
        self.init(
            uid: route.uid,
            connectionID: route.connectionID,
            sourceDeviceID: route.sourceDeviceID,
            transportNodeID: route.transportNodeID,
            authorityPeerNodeID: route.authorityPeerNodeID,
            generation: route.generation,
            accountGeneration: route.accountGeneration,
            expiresAt: route.expiresAt
        )
    }

    init(_ metadata: ComputerUseSessionGrantBroker.AcquisitionMetadata) {
        self.init(
            uid: metadata.uid,
            connectionID: metadata.connectionID,
            sourceDeviceID: metadata.sourceDeviceID,
            transportNodeID: metadata.transportPeerNodeID,
            authorityPeerNodeID: metadata.authorityPeerNodeID,
            generation: metadata.routeGeneration,
            accountGeneration: metadata.accountGeneration,
            expiresAt: metadata.routeExpiresAt
        )
    }
}

/// Synchronous secret-provider bridge required by `IrohXcframeworkTransport`.
/// Values are published only after the daemon has loaded them from an approved
/// Linux SecretStore backend and are removed when the owning runtime deallocates.
/// AUDIT(@unchecked Sendable): mutable key material is read/published/cleared
/// only under `lock`. sendable-allowlist: nslock-protected-storage
final class LinuxIrohEndpointSecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var secret: IrohSecretKeyMaterial?

    func require() throws -> IrohSecretKeyMaterial {
        lock.lock()
        defer { lock.unlock() }
        guard let secret else { throw LinuxIrohControllerRuntime.RuntimeError.identityUnavailable }
        return secret
    }

    func publish(_ secret: IrohSecretKeyMaterial) {
        lock.lock()
        self.secret = secret
        lock.unlock()
    }

    func clear() {
        lock.lock()
        secret = nil
        lock.unlock()
    }

}
#endif
