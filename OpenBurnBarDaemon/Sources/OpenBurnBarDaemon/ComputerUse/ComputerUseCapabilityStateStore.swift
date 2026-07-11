import Foundation
import OpenBurnBarComputerUseCore

protocol ComputerUseCapabilityStateProviding: Sendable {
    func currentState() async throws -> ComputerUseCapabilityStateSnapshot
}

enum ComputerUseCapabilityStateError: Error, Equatable, Sendable {
    case missing
    case incomplete
    case invalid
    case wrongQuotaDay
    case stale
    case futureDated
    case unsupportedSchema(Int)
    case rolledBack
}

/// Daemon-owned durable projection of app-owned Computer Use authorities.
///
/// Only the authenticated `computer_use` RPC can update this store. Persistence
/// makes daemon restarts safe; the freshness deadline makes a stranded snapshot
/// non-authoritative when the app is gone or its listeners stop publishing.
actor ComputerUseCapabilityStateStore: ComputerUseCapabilityStateProviding {
    static let defaultMaximumAge: TimeInterval = 120
    static let defaultMaximumFutureSkew: TimeInterval = 15

    private struct Envelope: Codable, Sendable {
        let schemaVersion: Int
        let state: ComputerUseCapabilityStateSnapshot
    }

    private struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let maximumAge: TimeInterval
    private let maximumFutureSkew: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedState: ComputerUseCapabilityStateSnapshot?
    private var didLoad = false

    init(
        fileURL: URL = BurnBarDaemonPaths.defaultComputerUseCapabilityStateURL,
        maximumAge: TimeInterval = ComputerUseCapabilityStateStore.defaultMaximumAge,
        maximumFutureSkew: TimeInterval = ComputerUseCapabilityStateStore.defaultMaximumFutureSkew,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.maximumAge = maximumAge
        self.maximumFutureSkew = maximumFutureSkew
        self.now = now
    }

    func update(
        _ state: ComputerUseCapabilityStateSnapshot
    ) throws -> ComputerUseCapabilityStateUpdateResponse {
        try validateShapeAndFreshness(state)
        let previous: ComputerUseCapabilityStateSnapshot?
        do {
            previous = try loadIfNeeded()
        } catch ComputerUseCapabilityStateError.unsupportedSchema(_) {
            // A validated current-schema publication is allowed to replace a
            // durable snapshot from an older app/daemon contract.
            cachedState = nil
            didLoad = true
            previous = nil
        }
        if let previous {
            if previous.publisherInstanceID == state.publisherInstanceID {
                guard state.revision > previous.revision else {
                    throw ComputerUseCapabilityStateError.rolledBack
                }
            } else {
                guard state.generatedAt > previous.generatedAt else {
                    throw ComputerUseCapabilityStateError.rolledBack
                }
            }
        }

        try persist(state)
        cachedState = state
        didLoad = true
        return ComputerUseCapabilityStateUpdateResponse(
            accepted: true,
            publisherInstanceID: state.publisherInstanceID,
            revision: state.revision,
            expiresAt: state.generatedAt.addingTimeInterval(maximumAge)
        )
    }

    func currentState() throws -> ComputerUseCapabilityStateSnapshot {
        guard let state = try loadIfNeeded() else {
            throw ComputerUseCapabilityStateError.missing
        }
        try validateShapeAndFreshness(state)
        guard state.isComplete else {
            throw ComputerUseCapabilityStateError.incomplete
        }
        return state
    }

    private func validateShapeAndFreshness(
        _ state: ComputerUseCapabilityStateSnapshot
    ) throws {
        guard state.schemaVersion == ComputerUseCapabilityStateSnapshot.currentSchemaVersion else {
            throw ComputerUseCapabilityStateError.unsupportedSchema(state.schemaVersion)
        }
        guard !state.publisherInstanceID.isEmpty,
              state.revision > 0,
              !state.isComplete || !state.userID.isEmpty,
              state.budgetEnvelope.activeActionsPerRun >= 0,
              state.budgetEnvelope.activeActionsPerDay >= 0,
              state.budgetEnvelope.activeSessionsPerDay >= 0,
              state.budgetEnvelope.perUserDailySpendCeilingUSD >= 0,
              state.quotaUsage.browserActionsExecuted >= 0,
              state.quotaUsage.browserActionsRejected >= 0,
              state.quotaUsage.systemActionsExecuted >= 0,
              state.quotaUsage.systemActionsRejected >= 0,
              state.quotaUsage.phoneControlIntentsExecuted >= 0,
              state.quotaUsage.phoneControlIntentsRejected >= 0,
              state.quotaUsage.sessionsStarted >= 0,
              state.quotaUsage.sessionsCompleted >= 0,
              state.quotaUsage.totalSessionSeconds >= 0,
              state.quotaUsage.visionModelSpendUSD >= 0 else {
            throw ComputerUseCapabilityStateError.invalid
        }
        let current = now()
        guard state.generatedAt <= current.addingTimeInterval(maximumFutureSkew) else {
            throw ComputerUseCapabilityStateError.futureDated
        }
        guard current.timeIntervalSince(state.generatedAt) <= maximumAge else {
            throw ComputerUseCapabilityStateError.stale
        }
        if state.isComplete {
            try validateAuthorityProvenance(state, current: current)
            if state.quotaUsage.dayKey != Self.dayKey(for: current) {
                throw ComputerUseCapabilityStateError.wrongQuotaDay
            }
        }
    }

    private func validateAuthorityProvenance(
        _ state: ComputerUseCapabilityStateSnapshot,
        current: Date
    ) throws {
        let provenances = [
            state.entitlementProvenance,
            state.budgetProvenance,
            state.quotaProvenance
        ]
        guard provenances.allSatisfy({
            ComputerUseCapabilityFreshness.sourceIsFresh($0, now: current)
        }) else {
            throw ComputerUseCapabilityStateError.stale
        }
        guard state.budgetProvenance.source == .firestoreServer,
              state.quotaProvenance.source == .firestoreServer else {
            throw ComputerUseCapabilityStateError.invalid
        }
        guard let budgetUpdatedAt = state.budgetProvenance.updatedAt,
              budgetUpdatedAt <= current.addingTimeInterval(maximumFutureSkew),
              current.timeIntervalSince(budgetUpdatedAt)
                <= ComputerUseCapabilityFreshness.maximumBudgetUpdateAge else {
            throw ComputerUseCapabilityStateError.stale
        }
        guard abs(state.budgetEnvelope.updatedAt.timeIntervalSince(budgetUpdatedAt)) < 0.001,
              state.quotaUsage.updatedAt == state.quotaProvenance.updatedAt else {
            throw ComputerUseCapabilityStateError.invalid
        }
    }

    private func loadIfNeeded() throws -> ComputerUseCapabilityStateSnapshot? {
        if didLoad { return cachedState }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let version = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        guard version.schemaVersion == ComputerUseCapabilityStateSnapshot.currentSchemaVersion else {
            throw ComputerUseCapabilityStateError.unsupportedSchema(version.schemaVersion)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        cachedState = envelope.state
        return envelope.state
    }

    private func persist(_ state: ComputerUseCapabilityStateSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let envelope = Envelope(
            schemaVersion: ComputerUseCapabilityStateSnapshot.currentSchemaVersion,
            state: state
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
