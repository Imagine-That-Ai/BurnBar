import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine

/// Daemon-owned rendezvous between one exact Linux Computer Use session
/// request and the paired phone grant that authorizes it. Proof material never
/// leaves this actor through status or acquisition results.
public actor ComputerUseSessionGrantBroker {
    public enum State: String, Sendable, Equatable {
        case awaitingPhone = "awaiting_phone"
        case ready
        case starting
        case expired
        case consumed
    }

    public enum BrokerError: Error, Sendable, Equatable {
        case invalidMetadata
        case rendererProofFieldsRejected
        case transportUnavailable
        case proofValidatorUnavailable
        case capacityExceeded
        case duplicateActiveIntent
        case challengeNotFound
        case challengeExpired
        case wrongAuthenticatedPeer
        case malformedSignedGrant
        case grantMismatch(field: String)
        case proofRejected
        case grantNotReady
        case alreadyConsumed
        case sessionRequestMismatch
        case startReservationMismatch
    }

    /// Metadata established by daemon-owned pairing and controller routing.
    /// Callers must not source peer or device identity from renderer JSON.
    public struct AcquisitionMetadata: Sendable, Equatable {
        public let uid: String
        public let connectionID: String
        public let transportPeerNodeID: String
        public let authorityPeerNodeID: String
        public let sourceDeviceID: String
        public let runtimeID: AssistantRuntimeID
        public let threadID: String
        public let preset: AgentPermissionPreset
        public let capabilities: Set<AgentDesktopCapability>
        public let routeGeneration: Int64
        public let routeExpiresAt: Date
        public let accountGeneration: UInt64

        public init(
            uid: String,
            connectionID: String,
            transportPeerNodeID: String,
            authorityPeerNodeID: String,
            sourceDeviceID: String,
            runtimeID: AssistantRuntimeID,
            threadID: String,
            preset: AgentPermissionPreset,
            capabilities: Set<AgentDesktopCapability>,
            routeGeneration: Int64 = 0,
            routeExpiresAt: Date = .distantFuture,
            accountGeneration: UInt64 = 0
        ) {
            self.uid = uid
            self.connectionID = connectionID
            self.transportPeerNodeID = transportPeerNodeID
            self.authorityPeerNodeID = authorityPeerNodeID
            self.sourceDeviceID = sourceDeviceID
            self.runtimeID = runtimeID
            self.threadID = threadID
            self.preset = preset
            self.capabilities = capabilities
            self.routeGeneration = routeGeneration
            self.routeExpiresAt = routeExpiresAt
            self.accountGeneration = accountGeneration
        }
    }

    public struct NonSecretStatus: Sendable, Equatable {
        public let challengeID: String
        public let sessionIntentID: String
        public let state: State
        public let issuedAt: Date
        public let expiresAt: Date
    }

    /// Internal result handed directly to the session-start implementation.
    /// It is deliberately not Codable and must never become an RPC response.
    struct PreparedSessionStart: Sendable, Equatable {
        let request: ComputerUseSessionStartRequest
    }

    /// Opaque single-owner lease for one session creation attempt. Holding the
    /// enriched request here keeps proof material inside daemon implementation
    /// code while the record's `.starting` state prevents concurrent reuse.
    struct StartReservation: Sendable, Equatable {
        fileprivate let reservationID: String
        fileprivate let challengeID: String
        let request: ComputerUseSessionStartRequest
        let metadata: AcquisitionMetadata
    }

    public typealias OutboundPublisher = @Sendable (
        _ transportPeerNodeID: String,
        _ frame: HermesRealtimeRelayFrame
    ) async throws -> Void
    public typealias PinnedPhoneGrantPrevalidator = @Sendable (
        _ request: HermesRealtimeRelayAgentGrantRequest,
        _ authorityPeerNodeID: String,
        _ now: Date
    ) async throws -> Void
    public typealias RandomBytes = @Sendable (_ count: Int) throws -> Data
    public typealias ChallengeIDGenerator = @Sendable () -> String
    public typealias Clock = @Sendable () -> Date

    public static let maximumChallengeLifetime: TimeInterval = 5 * 60
    public static let defaultMaximumRecords = 256
    public static let maximumRecordLimit = 4_096

    private struct VerifiedGrant: Sendable {
        let proof: HermesRealtimeRelayAgentGrantLocalAuthProof?
        let sourceDeviceID: String
        let intentHashHex: String
        let binding: ComputerUseLocalAuthGrantBinding
    }

    private struct Record: Sendable {
        let challenge: HermesRealtimeRelaySessionGrantChallenge
        let metadata: AcquisitionMetadata
        let transportPeerNodeID: String
        let authorityPeerNodeID: String
        let sourceDeviceID: String
        let originalRequest: ComputerUseSessionStartRequest
        var state: State
        var verifiedGrant: VerifiedGrant?
        var startReservationID: String?
        var terminalAt: Date?
    }

    private let publisher: OutboundPublisher?
    private let prevalidatePinnedPhoneGrant: PinnedPhoneGrantPrevalidator?
    public nonisolated let readinessReason: ComputerUseSessionGrantReadinessReason
    private let randomBytes: RandomBytes
    private let challengeIDGenerator: ChallengeIDGenerator
    private let clock: Clock
    private let challengeLifetime: TimeInterval
    private let terminalRetention: TimeInterval
    private let maximumRecords: Int
    private let signer: ComputerUsePhoneControlSigner
    private var records: [String: Record] = [:]

    public init(
        publisher: OutboundPublisher? = nil,
        prevalidatePinnedPhoneGrant: PinnedPhoneGrantPrevalidator? = nil,
        randomBytes: @escaping RandomBytes = { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        },
        challengeIDGenerator: @escaping ChallengeIDGenerator = { UUID().uuidString.lowercased() },
        clock: @escaping Clock = Date.init,
        challengeLifetime: TimeInterval = maximumChallengeLifetime,
        terminalRetention: TimeInterval = maximumChallengeLifetime,
        maximumRecords: Int = defaultMaximumRecords,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner()
    ) {
        self.publisher = publisher
        self.prevalidatePinnedPhoneGrant = prevalidatePinnedPhoneGrant
        if publisher == nil {
            self.readinessReason = .transportUnavailable
        } else if prevalidatePinnedPhoneGrant == nil {
            self.readinessReason = .proofValidatorUnavailable
        } else {
            self.readinessReason = .ready
        }
        self.randomBytes = randomBytes
        self.challengeIDGenerator = challengeIDGenerator
        self.clock = clock
        self.challengeLifetime = min(max(challengeLifetime, 1), Self.maximumChallengeLifetime)
        self.terminalRetention = min(max(terminalRetention, 0), Self.maximumChallengeLifetime)
        self.maximumRecords = min(max(maximumRecords, 1), Self.maximumRecordLimit)
        self.signer = signer
    }

    @discardableResult
    public func acquire(
        metadata: AcquisitionMetadata,
        request: ComputerUseSessionStartRequest,
        now: Date = Date()
    ) async throws -> NonSecretStatus {
        try rejectRendererProofFields(request)
        guard request.grantChallengeId == nil else {
            throw BrokerError.sessionRequestMismatch
        }
        guard let publisher else { throw BrokerError.transportUnavailable }
        guard Self.isBoundedIdentifier(metadata.uid),
              Self.isBoundedIdentifier(metadata.connectionID),
              Self.isBoundedIdentifier(metadata.transportPeerNodeID),
              Self.isBoundedIdentifier(metadata.authorityPeerNodeID),
              Self.isBoundedIdentifier(metadata.sourceDeviceID),
              Self.isBoundedIdentifier(metadata.threadID),
              metadata.preset != .off,
              metadata.capabilities.isEmpty == false,
              metadata.capabilities.isSubset(of: metadata.preset.capabilities) else {
            throw BrokerError.invalidMetadata
        }

        prune(now: now)
        guard records.count < maximumRecords else { throw BrokerError.capacityExceeded }

        let sessionIntentID = try signer.canonicalComputerUseSessionIntentID(request: request)
        if records.values.contains(where: {
            $0.challenge.sessionIntentId == sessionIntentID
                && ($0.state == .awaitingPhone || $0.state == .ready || $0.state == .starting)
        }) {
            throw BrokerError.duplicateActiveIntent
        }

        let challengeID = challengeIDGenerator()
        guard Self.isBoundedIdentifier(challengeID) else { throw BrokerError.invalidMetadata }
        let nonceBytes = try randomBytes(32)
        guard nonceBytes.count == 32 else { throw BrokerError.invalidMetadata }
        let nonce = nonceBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let expiresAt = now.addingTimeInterval(challengeLifetime)
        let challenge = HermesRealtimeRelaySessionGrantChallenge(
            version: ComputerUsePhoneControlSigner.sessionGrantChallengeVersion,
            challengeId: challengeID,
            nonce: nonce,
            issuedAt: now,
            expiresAt: expiresAt,
            sessionIntentId: sessionIntentID,
            runtime: metadata.runtimeID.rawValue,
            threadId: metadata.threadID,
            preset: metadata.preset.rawValue,
            capabilities: metadata.capabilities.map(\.rawValue).sorted(),
            mode: request.mode,
            trustMode: request.trustMode,
            scopeRuleIds: request.scopeRuleIds.sorted(),
            phoneViewerNodeId: request.phoneViewerNodeId,
            macHostNodeId: request.macHostNodeId,
            actionCap: request.actionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds,
            clientId: request.clientID.rawValue,
            runId: request.runID?.rawValue,
            runCallId: request.runCallID,
            runGeneration: request.runGeneration,
            desktopOwnerAuthorizationMethod: request.desktopOwnerAuthorizationRequest?.method.rawValue
        )
        _ = try signer.validateSessionGrantChallenge(challenge, now: now)

        records[challengeID] = Record(
            challenge: challenge,
            metadata: metadata,
            transportPeerNodeID: metadata.transportPeerNodeID,
            authorityPeerNodeID: metadata.authorityPeerNodeID,
            sourceDeviceID: metadata.sourceDeviceID,
            originalRequest: request,
            state: .awaitingPhone,
            verifiedGrant: nil,
            startReservationID: nil,
            terminalAt: nil
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlSessionGrantChallenge,
            uid: metadata.uid,
            connectionId: metadata.connectionID,
            requestId: challengeID,
            runtime: metadata.runtimeID.rawValue,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.agent.grant",
                sessionGrantChallenge: challenge
            )
        )
        do {
            try await publisher(metadata.transportPeerNodeID, frame)
        } catch {
            records.removeValue(forKey: challengeID)
            throw BrokerError.transportUnavailable
        }

        guard let currentRecord = records[challengeID] else {
            throw BrokerError.challengeNotFound
        }
        return Self.status(for: currentRecord)
    }

    /// Accepts only a live signed grant from the exact authenticated pairing
    /// peer. The injected prevalidator owns pinned-key signature, freshness,
    /// counter replay, and local-auth proof validation.
    public func ingest(
        _ wireRequest: HermesRealtimeRelayAgentGrantRequest,
        authenticatedTransportPeerNodeID: String,
        now: Date = Date()
    ) async throws {
        prune(now: now)
        guard let record = records[wireRequest.requestId] else {
            throw BrokerError.challengeNotFound
        }
        guard record.challenge.expiresAt > now, record.state != .expired else {
            throw BrokerError.challengeExpired
        }
        guard record.state == .awaitingPhone else {
            throw record.state == .consumed ? BrokerError.alreadyConsumed : BrokerError.grantNotReady
        }
        guard authenticatedTransportPeerNodeID == record.transportPeerNodeID,
              wireRequest.authority.peerNodeId == record.authorityPeerNodeID else {
            throw BrokerError.wrongAuthenticatedPeer
        }
        try exactMatch(wireRequest, record: record)
        guard let prevalidatePinnedPhoneGrant else {
            throw BrokerError.proofValidatorUnavailable
        }
        do {
            try await prevalidatePinnedPhoneGrant(wireRequest, record.authorityPeerNodeID, now)
        } catch {
            throw BrokerError.proofRejected
        }

        let validatedAt = clock()
        prune(now: validatedAt)
        guard var currentRecord = records[wireRequest.requestId] else {
            throw BrokerError.challengeNotFound
        }
        guard currentRecord.challenge.expiresAt > validatedAt,
              currentRecord.state != .expired else {
            throw BrokerError.challengeExpired
        }
        guard currentRecord.state == .awaitingPhone else {
            throw currentRecord.state == .consumed ? BrokerError.alreadyConsumed : BrokerError.grantNotReady
        }
        guard authenticatedTransportPeerNodeID == currentRecord.transportPeerNodeID,
              wireRequest.authority.peerNodeId == currentRecord.authorityPeerNodeID else {
            throw BrokerError.wrongAuthenticatedPeer
        }
        try exactMatch(wireRequest, record: currentRecord)

        let binding = ComputerUseLocalAuthGrantBinding(
            requestId: wireRequest.requestId,
            runtime: wireRequest.runtime,
            threadId: wireRequest.threadId,
            preset: wireRequest.preset,
            capabilities: wireRequest.capabilities,
            trustMode: wireRequest.trustMode,
            deliveryMode: wireRequest.deliveryMode,
            requestedAt: wireRequest.requestedAt,
            expiresAt: wireRequest.expiresAt,
            grantDurationSeconds: wireRequest.grantDurationSeconds,
            sourceDeviceId: wireRequest.sourceDeviceId,
            clientIntentId: wireRequest.clientIntentId,
            localAuthenticationSatisfied: wireRequest.localAuthenticationSatisfied
        )
        currentRecord.verifiedGrant = VerifiedGrant(
            proof: wireRequest.localAuthProof,
            sourceDeviceID: wireRequest.sourceDeviceId,
            intentHashHex: wireRequest.authority.intentHashBlake3,
            binding: binding
        )
        currentRecord.state = .ready
        currentRecord.startReservationID = nil
        records[wireRequest.requestId] = currentRecord
    }

    public func status(challengeID: String, now: Date = Date()) -> NonSecretStatus? {
        prune(now: now)
        return records[challengeID].map(Self.status(for:))
    }

    /// Validates and enriches without consuming. The daemon uses this to
    /// prevalidate the pinned-phone proof before presenting a desktop-owner
    /// prompt; it must call `reserveForStart` after revalidating run state.
    func prepare(
        challengeID: String,
        request: ComputerUseSessionStartRequest,
        now: Date = Date()
    ) throws -> PreparedSessionStart {
        try rejectRendererProofFields(request)
        prune(now: now)
        guard let record = records[challengeID] else { throw BrokerError.challengeNotFound }
        guard record.challenge.expiresAt > now, record.state != .expired else {
            throw BrokerError.challengeExpired
        }
        if record.state == .consumed { throw BrokerError.alreadyConsumed }
        guard record.state == .ready, let grant = record.verifiedGrant else {
            throw BrokerError.grantNotReady
        }
        guard request.grantChallengeId == challengeID,
              proofFreeRequest(request, grantChallengeID: nil) == record.originalRequest,
              try signer.canonicalComputerUseSessionIntentID(request: request) == record.challenge.sessionIntentId else {
            throw BrokerError.sessionRequestMismatch
        }

        return PreparedSessionStart(request: ComputerUseSessionStartRequest(
            mode: request.mode,
            trustMode: request.trustMode,
            scopeRuleIds: request.scopeRuleIds,
            phoneViewerNodeId: request.phoneViewerNodeId,
            macHostNodeId: request.macHostNodeId,
            actionCap: request.actionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds,
            clientID: request.clientID,
            runID: request.runID,
            runCallID: request.runCallID,
            runGeneration: request.runGeneration,
            executionSurface: request.executionSurface,
            executionSurfaceSessionId: request.executionSurfaceSessionId,
            grantChallengeId: request.grantChallengeId,
            desktopOwnerAuthorizationRequest: request.desktopOwnerAuthorizationRequest,
            localAuthProof: grant.proof,
            sourceDeviceId: grant.sourceDeviceID,
            intentHashHex: grant.intentHashHex,
            localAuthGrantBinding: grant.binding
        ))
    }

    /// Reserves the verified grant for exactly one session-creation attempt.
    /// The returned proof-bearing request is internal-only; status remains
    /// non-secret and all concurrent reserve/prepare attempts fail closed.
    func reserveForStart(
        challengeID: String,
        request: ComputerUseSessionStartRequest,
        now: Date = Date()
    ) throws -> StartReservation {
        let prepared = try prepare(challengeID: challengeID, request: request, now: now)
        guard var record = records[challengeID], record.state == .ready else {
            throw BrokerError.grantNotReady
        }
        let reservationID = UUID().uuidString.lowercased()
        record.state = .starting
        record.startReservationID = reservationID
        records[challengeID] = record
        return StartReservation(
            reservationID: reservationID,
            challengeID: challengeID,
            request: prepared.request,
            metadata: record.metadata
        )
    }

    /// Commits terminal broker consumption only after session creation returns
    /// successfully. The proof is wiped before the actor releases isolation.
    func commitStartedSession(
        _ reservation: StartReservation,
        now: Date = Date()
    ) throws {
        guard var record = records[reservation.challengeID] else {
            throw BrokerError.challengeNotFound
        }
        if record.state == .consumed { throw BrokerError.alreadyConsumed }
        guard record.state == .starting,
              record.startReservationID == reservation.reservationID else {
            throw BrokerError.startReservationMismatch
        }
        makeConsumed(&record, now: now)
        records[reservation.challengeID] = record
    }

    /// A normal synchronous start error is authoritative evidence that no
    /// session escaped. Restore retryability only for the exact reservation and
    /// only while its challenge remains fresh.
    @discardableResult
    func restoreAfterDefiniteStartFailure(
        _ reservation: StartReservation,
        now: Date = Date()
    ) -> Bool {
        prune(now: now)
        guard var record = records[reservation.challengeID],
              record.state == .starting,
              record.startReservationID == reservation.reservationID,
              record.challenge.expiresAt > now,
              record.verifiedGrant != nil else {
            return false
        }
        record.state = .ready
        record.startReservationID = nil
        record.terminalAt = nil
        records[reservation.challengeID] = record
        return true
    }

    /// Cancellation or an ambiguous outcome can never restore reusable
    /// authority. This operation is token-bound and idempotent for an already
    /// terminal record.
    @discardableResult
    func consumeAfterAmbiguousStart(
        _ reservation: StartReservation,
        now: Date = Date()
    ) -> Bool {
        guard var record = records[reservation.challengeID] else { return false }
        if record.state == .consumed { return true }
        guard record.state == .starting,
              record.startReservationID == reservation.reservationID else {
            return false
        }
        makeConsumed(&record, now: now)
        records[reservation.challengeID] = record
        return true
    }

    /// Compatibility helper for existing internal tests and call sites that
    /// intentionally perform an immediate reserve+commit with no async gap.
    func prepareAndConsume(
        challengeID: String,
        request: ComputerUseSessionStartRequest,
        now: Date = Date()
    ) throws -> PreparedSessionStart {
        let reservation = try reserveForStart(challengeID: challengeID, request: request, now: now)
        try commitStartedSession(reservation, now: now)
        return PreparedSessionStart(request: reservation.request)
    }

    private func exactMatch(
        _ request: HermesRealtimeRelayAgentGrantRequest,
        record: Record
    ) throws {
        let challenge = record.challenge
        guard request.runtime == challenge.runtime else { throw BrokerError.grantMismatch(field: "runtime") }
        guard request.threadId == challenge.threadId else { throw BrokerError.grantMismatch(field: "thread_id") }
        guard request.preset == challenge.preset else { throw BrokerError.grantMismatch(field: "preset") }
        guard request.capabilities == challenge.capabilities else { throw BrokerError.grantMismatch(field: "capabilities") }
        guard request.trustMode == challenge.trustMode else { throw BrokerError.grantMismatch(field: "trust_mode") }
        guard request.deliveryMode == AgentGrantDeliveryMode.live.rawValue else {
            throw BrokerError.grantMismatch(field: "delivery_mode")
        }
        guard request.requestedAt == challenge.issuedAt else { throw BrokerError.grantMismatch(field: "requested_at") }
        guard request.expiresAt == challenge.expiresAt else { throw BrokerError.grantMismatch(field: "expires_at") }
        guard request.grantDurationSeconds == min(
            AgentCapabilityGrantRequest.defaultGrantDuration,
            TimeInterval(challenge.sessionTimeoutSeconds)
        ) else { throw BrokerError.grantMismatch(field: "grant_duration") }
        guard request.sourceDeviceId == record.sourceDeviceID else { throw BrokerError.grantMismatch(field: "source_device") }
        guard request.clientIntentId == challenge.sessionIntentId else { throw BrokerError.grantMismatch(field: "session_intent") }
        guard request.authority.intentHashBlake3.isEmpty == false,
              request.authority.signatureEd25519.isEmpty == false,
              request.authority.counter > 0,
              request.authority.timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw BrokerError.malformedSignedGrant
        }
    }

    private func rejectRendererProofFields(_ request: ComputerUseSessionStartRequest) throws {
        guard request.localAuthProof == nil,
              request.sourceDeviceId == nil,
              request.intentHashHex == nil,
              request.localAuthGrantBinding == nil,
              request.executionSurface != .safariExtension,
              request.executionSurfaceSessionId == nil else {
            throw BrokerError.rendererProofFieldsRejected
        }
    }

    private func proofFreeRequest(
        _ request: ComputerUseSessionStartRequest,
        grantChallengeID: String?
    ) -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: request.mode,
            trustMode: request.trustMode,
            scopeRuleIds: request.scopeRuleIds,
            phoneViewerNodeId: request.phoneViewerNodeId,
            macHostNodeId: request.macHostNodeId,
            actionCap: request.actionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds,
            clientID: request.clientID,
            runID: request.runID,
            runCallID: request.runCallID,
            runGeneration: request.runGeneration,
            executionSurface: request.executionSurface,
            executionSurfaceSessionId: request.executionSurfaceSessionId,
            grantChallengeId: grantChallengeID,
            desktopOwnerAuthorizationRequest: request.desktopOwnerAuthorizationRequest
        )
    }

    private func prune(now: Date) {
        for challengeID in Array(records.keys) {
            guard var record = records[challengeID] else { continue }
            let isAwaitingExpiry = record.state == .awaitingPhone || record.state == .ready
            if isAwaitingExpiry, record.challenge.expiresAt <= now {
                record.state = .expired
                record.verifiedGrant = nil
                record.startReservationID = nil
                record.terminalAt = now
                records[challengeID] = record
            } else if record.state == .starting,
                      record.challenge.expiresAt <= now {
                // A timed-out in-flight creation has an ambiguous outcome. It
                // must never become retryable or retain proof material.
                makeConsumed(&record, now: now)
                records[challengeID] = record
            }
            if let terminalAt = record.terminalAt,
               now.timeIntervalSince(terminalAt) >= terminalRetention {
                records.removeValue(forKey: challengeID)
            }
        }
    }

    private func makeConsumed(_ record: inout Record, now: Date) {
        record.state = .consumed
        record.verifiedGrant = nil
        record.startReservationID = nil
        record.terminalAt = now
    }

    private static func status(for record: Record) -> NonSecretStatus {
        NonSecretStatus(
            challengeID: record.challenge.challengeId,
            sessionIntentID: record.challenge.sessionIntentId,
            state: record.state,
            issuedAt: record.challenge.issuedAt,
            expiresAt: record.challenge.expiresAt
        )
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        guard value.isEmpty == false, value.utf8.count <= 512 else { return false }
        return value.allSatisfy { character in
            character.isASCII && character != "\n" && character != "\r"
        }
    }
}
