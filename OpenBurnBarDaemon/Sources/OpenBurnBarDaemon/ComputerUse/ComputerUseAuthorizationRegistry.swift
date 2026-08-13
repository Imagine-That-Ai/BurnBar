import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine

/// Shared authority for explicit Computer Use RPCs and daemon-internal agent
/// browser dispatch. Production enables lease enforcement; development and
/// focused tests can leave it disabled while retaining the same call path.
public actor ComputerUseAuthorizationRegistry {
    public struct Authorization: Sendable, Equatable {
        public let sessionID: ComputerUseSessionID
        public let runID: BurnBarRunID
        public let clientID: BurnBarClientID
        public let generation: UInt64?
        public let expiresAt: Date?
    }

    private let enforcementEnabled: Bool
    private var authorizations: [ComputerUseSessionID: Authorization] = [:]
    private var verifiedSessionExpiries: [ComputerUseSessionID: Date] = [:]
    private var sessionIDsByRunID: [BurnBarRunID: ComputerUseSessionID] = [:]
    private var reservedRunIDs: Set<BurnBarRunID> = []

    public init(enforcementEnabled: Bool) {
        self.enforcementEnabled = enforcementEnabled
    }

    public func reserve(runID: BurnBarRunID) -> Bool {
        guard sessionIDsByRunID[runID] == nil else { return false }
        return reservedRunIDs.insert(runID).inserted
    }

    public func releaseReservation(runID: BurnBarRunID) {
        reservedRunIDs.remove(runID)
    }

    public func bind(
        sessionID: ComputerUseSessionID,
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        generation: UInt64? = nil
    ) -> Bool {
        guard reservedRunIDs.contains(runID),
              sessionIDsByRunID[runID] == nil,
              authorizations[sessionID] == nil else {
            return false
        }
        reservedRunIDs.remove(runID)
        sessionIDsByRunID[runID] = sessionID
        authorizations[sessionID] = Authorization(
            sessionID: sessionID,
            runID: runID,
            clientID: clientID,
            generation: generation,
            expiresAt: nil
        )
        return true
    }

    public func authorize(
        sessionID: ComputerUseSessionID,
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        requestedTimeoutSeconds: Int,
        maximumLifetime: TimeInterval,
        absoluteExpiry: Date? = nil,
        now: Date = Date()
    ) {
        let requestedLifetime = requestedTimeoutSeconds > 0
            ? TimeInterval(requestedTimeoutSeconds)
            : maximumLifetime
        let lifetime = min(requestedLifetime, maximumLifetime)
        pruneExpired(now: now)
        guard sessionIDsByRunID[runID] == sessionID,
              let existing = authorizations[sessionID],
              existing.runID == runID,
              existing.clientID == clientID else {
            return
        }
        let sessionExpiry = now.addingTimeInterval(lifetime)
        let expiresAt = absoluteExpiry.map { min($0, sessionExpiry) } ?? sessionExpiry
        guard expiresAt > now else {
            revoke(sessionID: sessionID)
            return
        }
        authorizations[sessionID] = Authorization(
            sessionID: sessionID,
            runID: runID,
            clientID: clientID,
            generation: existing.generation,
            expiresAt: expiresAt
        )
    }

    public func authorizeVerifiedSession(
        sessionID: ComputerUseSessionID,
        requestedTimeoutSeconds: Int,
        maximumLifetime: TimeInterval,
        absoluteExpiry: Date? = nil,
        now: Date = Date()
    ) {
        let requestedLifetime = requestedTimeoutSeconds > 0
            ? TimeInterval(requestedTimeoutSeconds)
            : maximumLifetime
        let sessionExpiry = now.addingTimeInterval(min(requestedLifetime, maximumLifetime))
        let expiresAt = absoluteExpiry.map { min($0, sessionExpiry) } ?? sessionExpiry
        pruneExpired(now: now)
        guard expiresAt > now else {
            verifiedSessionExpiries.removeValue(forKey: sessionID)
            return
        }
        verifiedSessionExpiries[sessionID] = expiresAt
    }

    public func sessionID(for runID: BurnBarRunID) -> ComputerUseSessionID? {
        sessionIDsByRunID[runID]
    }

    public func binding(sessionID: ComputerUseSessionID) -> Authorization? {
        authorizations[sessionID]
    }

    public func binding(runID: BurnBarRunID) -> Authorization? {
        guard let sessionID = sessionIDsByRunID[runID] else { return nil }
        return authorizations[sessionID]
    }

    public func hasActiveBinding(
        runID: BurnBarRunID,
        generation: UInt64,
        now: Date = Date()
    ) -> Bool {
        pruneExpired(now: now)
        guard let authorization = binding(runID: runID),
              authorization.generation == generation else {
            return false
        }
        guard enforcementEnabled else { return true }
        return authorization.expiresAt ?? .distantPast > now
    }

    /// Verifies the complete immutable identity of one managed-run binding.
    ///
    /// Safari uses this stricter form because a run ID alone is not enough to
    /// distinguish a stale extension session or a replacement run generation.
    /// The caller must already know the exact Computer Use session selected by
    /// the Safari surface; this method never discovers or revokes a session by
    /// run ID alone.
    public func hasActiveBinding(
        sessionID: ComputerUseSessionID,
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        generation: UInt64,
        now: Date = Date()
    ) -> Bool {
        pruneExpired(now: now)
        guard sessionIDsByRunID[runID] == sessionID,
              let authorization = authorizations[sessionID],
              authorization.sessionID == sessionID,
              authorization.runID == runID,
              authorization.clientID == clientID,
              authorization.generation == generation else {
            return false
        }
        guard enforcementEnabled else { return true }
        return authorization.expiresAt ?? .distantPast > now
    }

    public func permits(
        sessionID: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        now: Date = Date()
    ) -> Bool {
        pruneExpired(now: now)
        guard let authorization = authorizations[sessionID] else { return false }
        let identityMatches = authorization.runID == invocation.runID
            && authorization.clientID == invocation.requestedBy
        guard identityMatches else { return false }
        guard enforcementEnabled else { return true }
        return authorization.expiresAt ?? .distantPast > now
    }

    public func contains(sessionID: ComputerUseSessionID, now: Date = Date()) -> Bool {
        pruneExpired(now: now)
        guard enforcementEnabled else { return authorizations[sessionID] != nil }
        return verifiedSessionExpiries[sessionID] ?? .distantPast > now
    }

    public func revoke(sessionID: ComputerUseSessionID) {
        verifiedSessionExpiries.removeValue(forKey: sessionID)
        if let authorization = authorizations.removeValue(forKey: sessionID),
           sessionIDsByRunID[authorization.runID] == sessionID {
            sessionIDsByRunID.removeValue(forKey: authorization.runID)
        }
    }

    public func revokeAll() {
        authorizations.removeAll()
        verifiedSessionExpiries.removeAll()
        sessionIDsByRunID.removeAll()
        reservedRunIDs.removeAll()
    }

    private func pruneExpired(now: Date) {
        guard enforcementEnabled else { return }
        verifiedSessionExpiries = verifiedSessionExpiries.filter { $0.value > now }
        let expired = authorizations.values.compactMap { authorization -> ComputerUseSessionID? in
            guard let expiresAt = authorization.expiresAt, expiresAt <= now else { return nil }
            return authorization.sessionID
        }
        for sessionID in expired {
            revoke(sessionID: sessionID)
        }
    }
}
