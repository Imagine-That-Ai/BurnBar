import Foundation

/// The Wire's admission decision — the one place that answers "may these two
/// Macs talk directly?" (§ The Wire of `plans/2026-08-17-war-room-master-plan.md`).
///
/// Deliberately pure and dependency-free so both the dialing side and the
/// answering side run the *same* evaluation, and so the fail-closed contract is
/// unit-testable without a transport, Firestore, or an entitlement service.
///
/// Fail-closed is the whole point: every unknown answers `deny`. A denied dial
/// is not an error — the caller falls back to the Firestore relay path, which
/// is why `WarWireDenialReason` is a closed vocabulary the fallback can log and
/// the Command Board can render.
public enum WarWireDenialReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// `war_room_kill_switch` is engaged (Remote Config, defaults to true).
    case killSwitch = "kill_switch"
    /// The account is below the Wire's required tier.
    case entitlement
    /// No grant document covers this pair.
    case noGrant = "no_grant"
    /// A grant exists but has been revoked from either machine.
    case grantRevoked = "grant_revoked"
    /// A grant was presented, but it does not cover this pair of bodies.
    case grantMismatch = "grant_mismatch"
    /// A body tried to dial itself.
    case selfDial = "self_dial"
    /// Either body id is missing or empty — identity could not be established.
    case unidentified
}

public enum WarWireDecision: Sendable, Equatable {
    case allow
    case deny(WarWireDenialReason)

    public var isAllowed: Bool {
        self == .allow
    }

    public var denialReason: WarWireDenialReason? {
        guard case let .deny(reason) = self else { return nil }
        return reason
    }
}

/// A `war_wire_grants` document in evaluated form — the mutual consent record
/// that lets two of an account's Macs open the Wire. Revocable from either
/// machine; anything not provably `active` reads as revoked.
public struct WarWireGrant: Sendable, Equatable, Hashable {
    public enum State: String, Codable, Sendable, Equatable, CaseIterable {
        case active
        case revoked
    }

    public var bodyIDA: String
    public var bodyIDB: String
    public var state: State

    public init(bodyIDA: String, bodyIDB: String, state: State) {
        self.bodyIDA = bodyIDA
        self.bodyIDB = bodyIDB
        self.state = state
    }

    /// The canonical document id for a pair: both body ids sorted
    /// lexicographically and joined with `__`, so either machine derives the
    /// same id without coordinating who is "first".
    public static func pairID(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "__")
    }

    public var pairID: String {
        Self.pairID(bodyIDA, bodyIDB)
    }

    /// `true` when this grant is the one covering the given pair, in either
    /// direction.
    public func covers(_ first: String, _ second: String) -> Bool {
        pairID == Self.pairID(first, second)
    }
}

public enum WarWireGate {
    /// The Wire is a Pro/Ultra lane. Lower tiers keep the existing Firestore
    /// relay experience unchanged — the Wire is an upgrade, never a dependency.
    public static let requiredTier: CloudTier = .pro

    /// Evaluate a Wire dial. Checks run global-stop first, then entitlement,
    /// then identity, then consent, so the reason returned is the outermost
    /// one that applies and the caller can render a truthful explanation.
    public static func evaluate(
        localBodyID: String,
        remoteBodyID: String,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grant: WarWireGrant?
    ) -> WarWireDecision {
        if killSwitchEngaged { return .deny(.killSwitch) }
        guard tier.satisfies(requiredTier) else { return .deny(.entitlement) }

        let local = localBodyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteBodyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !local.isEmpty, !remote.isEmpty else { return .deny(.unidentified) }
        guard local != remote else { return .deny(.selfDial) }

        guard let grant else { return .deny(.noGrant) }
        guard grant.covers(local, remote) else { return .deny(.grantMismatch) }
        guard grant.state == .active else { return .deny(.grantRevoked) }
        return .allow
    }
}
