import Foundation

/// Face B, the Hermes Room (§ The three faces of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// One question: which of my Macs is serving Hermes right now, and can I move
/// it? The answer to "can I move it to that one" is exactly the Wire's
/// admission question, so this reuses `WarWireGate` rather than restating the
/// rules — a machine the Wire would refuse is a machine the room shows as
/// unavailable, with the same reason and no second opinion.
public struct HermesRoomRow: Sendable, Equatable, Identifiable {
    public var id: String { body.bodyID }
    public var body: FleetBodySnapshot
    public var isActive: Bool
    /// Nil when this machine can be made active.
    public var blockedReason: WarWireDenialReason?

    public init(body: FleetBodySnapshot, isActive: Bool, blockedReason: WarWireDenialReason?) {
        self.body = body
        self.isActive = isActive
        self.blockedReason = blockedReason
    }

    public var isSelectable: Bool { blockedReason == nil && !isActive }

    /// One line, render-ready. The room never shows a bare "unavailable".
    public var statusLine: String {
        if body.isLocal { return isActive ? "Serving Hermes here" : "Ready to serve here" }
        guard let blockedReason else {
            return isActive ? "Serving Hermes over the Wire" : "Ready over the Wire"
        }
        switch blockedReason {
        case .killSwitch: return "The Wire is off"
        case .entitlement: return "Needs Cloud Pro"
        case .noGrant: return "Not linked to this Mac yet"
        case .grantRevoked: return "Link revoked"
        case .grantMismatch: return "Link does not cover this pair"
        case .selfDial: return "Ready to serve here"
        case .unidentified: return "Machine not identified"
        }
    }
}

public struct HermesRoomState: Sendable, Equatable {
    public var rows: [HermesRoomRow]

    public init(rows: [HermesRoomRow]) {
        self.rows = rows
    }

    /// The machine currently serving, if it is still in the fleet. Derived
    /// rather than stored so it cannot drift out of step with `rows`.
    public var activeRow: HermesRoomRow? { rows.first { $0.isActive } }

    public var isEmpty: Bool { rows.isEmpty }
}

public enum HermesRoom {

    /// Build the room.
    ///
    /// `activeBodyID` nil means the local machine is serving, which is the
    /// default and the pre-War Room behaviour. Offline machines are kept in the
    /// list rather than hidden: a Mac you cannot currently reach is exactly the
    /// thing you came to this screen to find out about.
    public static func state(
        fleet: FleetSnapshot,
        localBodyID: String,
        activeBodyID: String?,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grants: [String: WarWireGrant]
    ) -> HermesRoomState {
        let resolvedActive = activeBodyID ?? localBodyID

        let rows = fleet.bodies
            .sorted(by: order(localBodyID: localBodyID))
            .map { body -> HermesRoomRow in
                HermesRoomRow(
                    body: body,
                    isActive: body.bodyID == resolvedActive,
                    blockedReason: blockedReason(
                        for: body,
                        localBodyID: localBodyID,
                        tier: tier,
                        killSwitchEngaged: killSwitchEngaged,
                        grants: grants
                    )
                )
            }

        return HermesRoomState(rows: rows)
    }

    private static func blockedReason(
        for body: FleetBodySnapshot,
        localBodyID: String,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grants: [String: WarWireGrant]
    ) -> WarWireDenialReason? {
        // The local machine needs no Wire and no consent to serve Hermes; it is
        // already here.
        if body.bodyID == localBodyID { return nil }

        let pairID = WarWireGrant.pairID(localBodyID, body.bodyID)
        let decision = WarWireGate.evaluate(
            localBodyID: localBodyID,
            remoteBodyID: body.bodyID,
            tier: tier,
            killSwitchEngaged: killSwitchEngaged,
            grant: grants[pairID]
        )
        return decision.denialReason
    }

    /// This Mac first, then reachable machines, then by name. The list is read
    /// top-down by someone deciding where to put Hermes, so the machines they
    /// can actually pick belong at the top.
    private static func order(
        localBodyID: String
    ) -> (FleetBodySnapshot, FleetBodySnapshot) -> Bool {
        { lhs, rhs in
            if (lhs.bodyID == localBodyID) != (rhs.bodyID == localBodyID) {
                return lhs.bodyID == localBodyID
            }
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.bodyID < rhs.bodyID
        }
    }
}
