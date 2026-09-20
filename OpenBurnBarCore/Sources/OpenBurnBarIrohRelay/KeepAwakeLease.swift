import Foundation

/// Reasons that hold a Mac idle-sleep assertion. Display may still sleep.
/// Lid-close `pmset disablesleep` is never implied by these reasons.
public enum KeepAwakeReason: String, Sendable, Codable, CaseIterable, Hashable {
    case mercuryMirror
    case computerUse
    case irohControl
    case phoneToggle
}

/// Refcounted-by-reason lease. The assertion is held while any reason is
/// active and released when the last reason drops. Acquire/release of the
/// same reason is idempotent — two mirrors share one `mercuryMirror` hold.
public struct KeepAwakeLease: Equatable, Sendable {
    public private(set) var reasons: Set<KeepAwakeReason>

    public init(reasons: Set<KeepAwakeReason> = []) {
        self.reasons = reasons
    }

    public var isHeld: Bool { !reasons.isEmpty }

    /// `true` when this acquire moved the lease from empty to held.
    @discardableResult
    public mutating func acquire(_ reason: KeepAwakeReason) -> Bool {
        let wasHeld = isHeld
        reasons.insert(reason)
        return !wasHeld
    }

    /// `true` when this release moved the lease from held to empty.
    @discardableResult
    public mutating func release(_ reason: KeepAwakeReason) -> Bool {
        let wasHeld = isHeld
        reasons.remove(reason)
        return wasHeld && !isHeld
    }

    @discardableResult
    public mutating func set(_ reason: KeepAwakeReason, held: Bool) -> Bool {
        held ? acquire(reason) : release(reason)
    }
}

/// Honest reachability the phone can show: awake vs last-seen.
/// `lidCloseSleepDisabled` is always false unless an admin later enables
/// the gated `pmset` option — keep-awake never flips it.
public struct HostReachabilityStatus: Equatable, Sendable, Codable {
    public var isAwake: Bool
    public var lastSeenAt: Date
    public var reasons: [KeepAwakeReason]
    public var lidCloseSleepDisabled: Bool
    /// Sticky phone switch, distinct from a live-session auto-arm.
    public var phoneToggleHeld: Bool

    public init(
        isAwake: Bool,
        lastSeenAt: Date,
        reasons: [KeepAwakeReason] = [],
        lidCloseSleepDisabled: Bool = LidCloseSleepPolicy.disablesSleepByDefault,
        phoneToggleHeld: Bool = false
    ) {
        self.isAwake = isAwake
        self.lastSeenAt = lastSeenAt
        self.reasons = reasons
        self.lidCloseSleepDisabled = lidCloseSleepDisabled
        self.phoneToggleHeld = phoneToggleHeld
    }

    public static func asleep(lastSeenAt: Date) -> HostReachabilityStatus {
        HostReachabilityStatus(isAwake: false, lastSeenAt: lastSeenAt)
    }

    public static func awake(
        lastSeenAt: Date,
        reasons: Set<KeepAwakeReason>
    ) -> HostReachabilityStatus {
        HostReachabilityStatus(
            isAwake: true,
            lastSeenAt: lastSeenAt,
            reasons: KeepAwakeReason.allCases.filter { reasons.contains($0) },
            phoneToggleHeld: reasons.contains(.phoneToggle)
        )
    }

    public var presenceCapabilities: [String] {
        var capabilities = [
            isAwake ? HostReachabilityCapability.held : HostReachabilityCapability.asleep
        ]
        if phoneToggleHeld {
            capabilities.append(HostReachabilityCapability.phoneToggle)
        }
        return capabilities
    }

    public static func fromPresence(
        capabilities: [String],
        lastSeenAt: Date
    ) -> HostReachabilityStatus {
        HostReachabilityStatus(
            isAwake: capabilities.contains(HostReachabilityCapability.held),
            lastSeenAt: lastSeenAt,
            phoneToggleHeld: capabilities.contains(HostReachabilityCapability.phoneToggle)
        )
    }
}

public enum HostReachabilityCapability {
    public static let held = "openburnbar.keep_awake.held"
    public static let asleep = "openburnbar.keep_awake.asleep"
    public static let phoneToggle = "openburnbar.keep_awake.phone_toggle"
    public static let togglePrefix = "openburnbar.keep_awake.toggle.v1:"
}

/// Lid-close `pmset disablesleep` stays an explicit admin-gated advanced
/// option. The keep-awake lease never enables it.
public enum LidCloseSleepPolicy {
    public static let disablesSleepByDefault = false
}
