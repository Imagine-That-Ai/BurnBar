import Foundation
import OpenBurnBarCore

/// T-TRN-03 — guard rails around iroh→Firestore transport downgrade.
///
/// Two distinct protections, both pure so they are unit-testable without a live
/// transport:
///
/// 1. **Control-plane downgrade restriction.** A silent auto-downgrade of a
///    CONTROL-plane stream from the peer-to-peer iroh transport to the
///    cloud-visible Firestore transport widens the attack surface (the relay/
///    backend sees control traffic it could not see over iroh). The existing
///    composite already hard-fails the *selected-model* chat stream; this
///    classifier additionally names which operations are control-plane so the
///    caller can require an explicit condition (e.g. the iroh transport being
///    disabled, or a non-security iroh error) before allowing the downgrade.
///
/// 2. **Fallback-rate alarm.** A burst of fallbacks is a signal that something is
///    forcing traffic onto the cloud path (a relay outage — or an attacker
///    suppressing iroh to harvest cloud-visible metadata). ``FallbackRateAlarm``
///    is a sliding-window counter that fires once when the fallback count in the
///    window crosses a threshold, so the caller can emit a single elevated audit
///    event instead of one-per-fallback noise.
enum HermesTransportDowngradePolicy {
    /// CONTROL-plane operations: everything that is NOT a model/agent *content*
    /// stream. These target the same selected executor regardless of transport,
    /// so the composite still allows their fallback, but a downgrade of one is
    /// audited at elevated severity and gated on the explicit conditions below.
    static func isControlPlane(_ operation: HermesRelayOperation) -> Bool {
        switch operation {
        case .chatCompletions, .cliAgentChat:
            return false
        case .cliAgentModelCatalog, .cliAgentSessionAction, .models, .sessions, .sessionDetail, .profiles, .jobs:
            return true
        }
    }

    /// Whether a silent auto-downgrade of this operation may proceed.
    ///
    /// - `irohEnabled`: when iroh is administratively OFF, taking the cloud path
    ///   is the user's configured choice, not a downgrade — always allowed.
    /// - `errorStopsFallback`: a security/model-binding error already halts
    ///   fallback upstream; if set we never reach here, but we double-gate.
    ///
    /// For control-plane ops with iroh ENABLED we still allow the fallback (these
    /// ops are transport-agnostic), but the caller MUST audit it as a downgrade.
    /// The method returns whether the downgrade is *permitted at all*; the audit
    /// is the caller's responsibility (see `HermesCompositeRelayTransport`).
    static func allowsSilentDowngrade(
        operation: HermesRelayOperation,
        irohEnabled: Bool,
        errorStopsFallback: Bool
    ) -> Bool {
        if errorStopsFallback { return false }
        if !irohEnabled { return true }
        // iroh enabled: content streams are gated elsewhere (selected-model
        // hard-fail); control-plane streams may fall back but are audited.
        return true
    }
}

/// Sliding-window fallback-rate alarm. Thread-safe; the composite transport holds
/// one shared instance. `record(at:)` returns `true` exactly once each time the
/// count within `window` crosses `threshold` (re-arms after the window drains
/// below the threshold), so a burst yields a single elevated audit event.
final class FallbackRateAlarm: @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Int
    private let window: TimeInterval
    private var timestamps: [Date] = []
    private var armed = true

    init(threshold: Int = 5, window: TimeInterval = 60) {
        self.threshold = max(1, threshold)
        self.window = max(1, window)
    }

    /// Record a fallback at `now`. Returns `true` only on the transition into the
    /// alarmed state, so callers can fire a single alert per burst.
    func record(at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        timestamps.removeAll { $0 < cutoff }
        timestamps.append(now)
        if timestamps.count >= threshold {
            guard armed else { return false }
            armed = false
            return true
        }
        // Re-arm once the window has drained back below the threshold.
        if timestamps.count < threshold {
            armed = true
        }
        return false
    }

    /// Test/diagnostics helper: current count within the window at `now`.
    func count(at now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        return timestamps.filter { $0 >= cutoff }.count
    }
}
