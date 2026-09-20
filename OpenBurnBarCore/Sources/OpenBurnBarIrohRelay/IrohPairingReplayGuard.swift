import Foundation

extension IrohPairingRecord {
    /// Stable dedup key for in-window replay rejection. Binds uid, connection, and
    /// the Ed25519 signature bytes so a captured record cannot be dialed twice
    /// inside the freshness window.
    var replayConsumptionKey: String {
        "\(uid)|\(connectionId)|\(signature)"
    }
}

/// Durable store for pairing replay keys. A new `IrohPairingReplayGuard`
/// constructed against the same store is a relaunch: keys consumed by a
/// previous process are inherited and rejected.
public protocol IrohPairingReplayPersisting: Sendable {
    func loadConsumed() throws -> [String: Date]
    func saveConsumed(_ consumed: [String: Date]) throws
}

/// JSON file persistence. Corrupt or unreadable files fail closed.
public struct IrohPairingReplayFileStore: IrohPairingReplayPersisting {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default on-disk location used by the mobile dial path.
    public static func applicationSupportStore() throws -> IrohPairingReplayFileStore {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("OpenBurnBar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return IrohPairingReplayFileStore(
            url: dir.appendingPathComponent("iroh-pairing-replay.json")
        )
    }

    public func loadConsumed() throws -> [String: Date] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IrohPairingError.replayStoreUnavailable
        }
        if data.isEmpty { return [:] }
        let raw: [String: Double]
        do {
            raw = try JSONDecoder().decode([String: Double].self, from: data)
        } catch {
            throw IrohPairingError.replayStoreUnavailable
        }
        var parsed: [String: Date] = [:]
        parsed.reserveCapacity(raw.count)
        for (key, epoch) in raw {
            parsed[key] = Date(timeIntervalSince1970: epoch)
        }
        return parsed
    }

    public func saveConsumed(_ consumed: [String: Date]) throws {
        var raw: [String: Double] = [:]
        raw.reserveCapacity(consumed.count)
        for (key, date) in consumed {
            raw[key] = date.timeIntervalSince1970
        }
        let data = try JSONEncoder().encode(raw)
        try data.write(to: url, options: .atomic)
    }
}

/// Rejects presenting the same signed pairing record more than once within the
/// freshness window (T-TRN-05) **across process launches**. Same-process
/// reconnects of a record this guard already accepted are allowed so Mac
/// republish (every ~60s) vs client retry (every few seconds) does not storm.
///
/// A captured snapshot presented to a **new** guard instance that loaded the
/// same store is `.replayed`. That is the 2026-07-03 swallow replacement:
/// reconnects still work; relaunch does not.
public actor IrohPairingReplayGuard {
    private var sessionConsumedAt: [String: Date] = [:]
    private var inheritedConsumedAt: [String: Date] = [:]
    private var persistenceState: PersistenceState
    private let persistence: (any IrohPairingReplayPersisting)?

    private enum PersistenceState {
        case pending
        case ready
        case unavailable
    }

    public init(persistence: (any IrohPairingReplayPersisting)? = nil) {
        self.persistence = persistence
        self.persistenceState = persistence == nil ? .ready : .pending
    }

    /// True when this process already accepted `record`. Used by
    /// `fetchAndVerify` so the 30-minute live window applies only after a
    /// successful idle-bound first dial in this process — the phone cannot
    /// assert liveness on a record it has never freshly verified.
    public func hasConsumedInThisSession(_ record: IrohPairingRecord) -> Bool {
        sessionConsumedAt[record.replayConsumptionKey] != nil
    }

    public func consume(
        record: IrohPairingRecord,
        now: Date = Date(),
        maximumAge: TimeInterval = IrohPairingFreshness.maximumAgeSeconds
    ) throws {
        try ensureLoaded()
        pruneExpired(now: now, maximumAge: maximumAge)
        let key = record.replayConsumptionKey
        if sessionConsumedAt[key] != nil {
            return
        }
        if inheritedConsumedAt[key] != nil {
            throw IrohPairingError.replayed
        }
        sessionConsumedAt[key] = now
        try persistMerged()
    }

    private func ensureLoaded() throws {
        guard persistenceState == .pending else {
            if persistenceState == .unavailable {
                throw IrohPairingError.replayStoreUnavailable
            }
            return
        }
        guard let persistence else {
            persistenceState = .ready
            return
        }
        do {
            inheritedConsumedAt = try persistence.loadConsumed()
            persistenceState = .ready
        } catch IrohPairingError.replayStoreUnavailable {
            persistenceState = .unavailable
            throw IrohPairingError.replayStoreUnavailable
        } catch {
            persistenceState = .unavailable
            throw IrohPairingError.replayStoreUnavailable
        }
    }

    private func persistMerged() throws {
        guard let persistence else { return }
        var merged = inheritedConsumedAt
        for (key, date) in sessionConsumedAt {
            merged[key] = date
        }
        do {
            try persistence.saveConsumed(merged)
        } catch {
            throw IrohPairingError.replayStoreUnavailable
        }
    }

    private func pruneExpired(now: Date, maximumAge: TimeInterval) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        sessionConsumedAt = sessionConsumedAt.filter { $0.value >= cutoff }
        inheritedConsumedAt = inheritedConsumedAt.filter { $0.value >= cutoff }
    }
}

/// Persistence that always fails closed. Used when the on-disk store cannot
/// be created so pairing never silently drops replay protection.
public struct IrohPairingReplayUnavailableStore: IrohPairingReplayPersisting {
    public init() {}

    public func loadConsumed() throws -> [String: Date] {
        throw IrohPairingError.replayStoreUnavailable
    }

    public func saveConsumed(_ consumed: [String: Date]) throws {
        throw IrohPairingError.replayStoreUnavailable
    }
}

public enum IrohPairingReplayGuardShared {
    /// Process-scoped guard used by mobile dial paths. Persistence is the
    /// application-support JSON file so a relaunch inherits consumed keys.
    /// If that file cannot be created, consume fails closed.
    public static let session: IrohPairingReplayGuard = {
        do {
            let store = try IrohPairingReplayFileStore.applicationSupportStore()
            return IrohPairingReplayGuard(persistence: store)
        } catch {
            return IrohPairingReplayGuard(persistence: IrohPairingReplayUnavailableStore())
        }
    }()
}
