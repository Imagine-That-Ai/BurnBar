import Foundation

/// Which Macs should the Wire be talking to right now?
///
/// The host that owns sockets is a thin loop in the app; the decision of who to
/// dial, who to hang up on, and who to leave alone lives here, so the
/// fail-closed contract is unit-testable without a transport, Firestore, or an
/// entitlement service.
public struct WarWirePeer: Sendable, Equatable {
    public var bodyID: String
    public var displayName: String
    /// The peer's published iroh endpoint. `nil` when the body doc carries no
    /// endpoint yet, which is a reachability fact rather than a refusal.
    public var irohNodeID: String?
    public var isOnline: Bool

    public init(bodyID: String, displayName: String, irohNodeID: String?, isOnline: Bool) {
        self.bodyID = bodyID
        self.displayName = displayName
        self.irohNodeID = irohNodeID
        self.isOnline = isOnline
    }
}

public struct WarWireDialIntent: Sendable, Equatable {
    public var bodyID: String
    public var displayName: String
    public var nodeID: String

    public init(bodyID: String, displayName: String, nodeID: String) {
        self.bodyID = bodyID
        self.displayName = displayName
        self.nodeID = nodeID
    }
}

/// An open link the gate no longer allows. Consent pulled on either machine has
/// to close lanes that are already up, otherwise "revoke" only means "do not
/// dial again" and the lane outlives the permission.
public struct WarWireDrop: Sendable, Equatable {
    public var bodyID: String
    public var reason: WarWireDenialReason

    public init(bodyID: String, reason: WarWireDenialReason) {
        self.bodyID = bodyID
        self.reason = reason
    }
}

public struct WarWireSkip: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The gate refused. Carries the vocabulary the UI renders.
        case denied(WarWireDenialReason)
        case offline
        case alreadyLinked
        /// Allowed and online, but the body publishes no iroh endpoint, so
        /// there is nothing to dial. Distinct from a refusal on purpose: one is
        /// a permission answer, the other is a reachability answer, and
        /// collapsing them would tell the user consent is missing when it isn't.
        case noEndpoint
    }

    public var bodyID: String
    public var reason: Reason

    public init(bodyID: String, reason: Reason) {
        self.bodyID = bodyID
        self.reason = reason
    }
}

public struct WarWirePlan: Sendable, Equatable {
    public var dials: [WarWireDialIntent]
    public var drops: [WarWireDrop]
    public var skips: [WarWireSkip]

    public init(dials: [WarWireDialIntent], drops: [WarWireDrop], skips: [WarWireSkip]) {
        self.dials = dials
        self.drops = drops
        self.skips = skips
    }

    public var isEmpty: Bool { dials.isEmpty && drops.isEmpty && skips.isEmpty }
}

public enum WarWirePlanner {

    /// Decide the Wire's next move for every known peer.
    ///
    /// Every peer is accounted for in exactly one bucket, so a machine can never
    /// silently vanish from the Hermes Room without a reason attached.
    public static func plan(
        peers: [WarWirePeer],
        localBodyID: String,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grants: [WarWireGrant],
        linkedBodyIDs: Set<String>
    ) -> WarWirePlan {
        var dials: [WarWireDialIntent] = []
        var drops: [WarWireDrop] = []
        var skips: [WarWireSkip] = []

        for peer in peers.sorted(by: { $0.bodyID < $1.bodyID }) {
            let decision = WarWireGate.evaluate(
                localBodyID: localBodyID,
                remoteBodyID: peer.bodyID,
                tier: tier,
                killSwitchEngaged: killSwitchEngaged,
                grant: grants.first { $0.covers(localBodyID, peer.bodyID) }
            )

            // An existing link is re-checked against the gate every pass, so a
            // grant revoked mid-session closes the lane instead of surviving
            // until the next disconnect.
            if linkedBodyIDs.contains(peer.bodyID) {
                if let reason = decision.denialReason {
                    drops.append(WarWireDrop(bodyID: peer.bodyID, reason: reason))
                } else {
                    skips.append(WarWireSkip(bodyID: peer.bodyID, reason: .alreadyLinked))
                }
                continue
            }

            if let reason = decision.denialReason {
                skips.append(WarWireSkip(bodyID: peer.bodyID, reason: .denied(reason)))
                continue
            }
            guard peer.isOnline else {
                skips.append(WarWireSkip(bodyID: peer.bodyID, reason: .offline))
                continue
            }
            guard let nodeID = peer.irohNodeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !nodeID.isEmpty else {
                skips.append(WarWireSkip(bodyID: peer.bodyID, reason: .noEndpoint))
                continue
            }

            dials.append(
                WarWireDialIntent(bodyID: peer.bodyID, displayName: peer.displayName, nodeID: nodeID)
            )
        }

        return WarWirePlan(dials: dials, drops: drops, skips: skips)
    }
}
