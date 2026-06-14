import Foundation

extension IrohPairingRecord {
    /// Stable dedup key for in-window replay rejection. Binds uid, connection, and
    /// the Ed25519 signature bytes so a captured record cannot be dialed twice
    /// inside the freshness window.
    var replayConsumptionKey: String {
        "\(uid)|\(connectionId)|\(signature)"
    }
}

/// Rejects presenting the same signed pairing record more than once within the
/// freshness window (T-TRN-05). Mac heartbeats mint fresh signatures, so
/// legitimate re-publishes are not blocked.
public actor IrohPairingReplayGuard {
    private var consumedAt: [String: Date] = [:]

    public init() {}

    public func consume(record: IrohPairingRecord, now: Date = Date()) throws {
        pruneExpired(now: now)
        let key = record.replayConsumptionKey
        if consumedAt[key] != nil {
            throw IrohPairingError.replayed
        }
        consumedAt[key] = now
    }

    private func pruneExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-IrohPairingFreshness.maximumAgeSeconds)
        consumedAt = consumedAt.filter { $0.value >= cutoff }
    }
}

public enum IrohPairingReplayGuardShared {
    /// Process-scoped guard used by mobile dial paths.
    public static let session = IrohPairingReplayGuard()
}