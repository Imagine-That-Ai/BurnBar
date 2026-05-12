import Foundation

// MARK: - Smart Display Repair Status
//
// Shared macOS/iOS progress contract for "make the display work" flows.
// A repair is not successful just because a command was accepted: it must
// reach `working`, or it must tell the user what physical action is needed.

public enum SmartDisplayRepairPhase: String, Codable, Sendable, Equatable {
    case idle
    case detecting
    case repairing
    case waitingForProof
    case working
    case needsUserAction
    case failed
    case skipped
}

public struct SmartDisplayDeviceRepairStatus: Codable, Sendable, Equatable {
    public var kind: SmartDisplayKind
    public var phase: SmartDisplayRepairPhase
    public var message: String
    public var proof: String?
    public var updatedAt: Date

    public init(
        kind: SmartDisplayKind,
        phase: SmartDisplayRepairPhase,
        message: String,
        proof: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.kind = kind
        self.phase = phase
        self.message = message
        self.proof = proof
        self.updatedAt = updatedAt
    }

    public var isTerminal: Bool {
        switch phase {
        case .working, .needsUserAction, .failed, .skipped:
            return true
        case .idle, .detecting, .repairing, .waitingForProof:
            return false
        }
    }

    public var isHealthy: Bool {
        phase == .working
    }
}

public struct SmartDisplayRepairReport: Codable, Sendable, Equatable {
    public var nestHub: SmartDisplayDeviceRepairStatus?
    public var pixelClock: SmartDisplayDeviceRepairStatus?
    public var startedAt: Date
    public var completedAt: Date?

    public init(
        nestHub: SmartDisplayDeviceRepairStatus? = nil,
        pixelClock: SmartDisplayDeviceRepairStatus? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.nestHub = nestHub
        self.pixelClock = pixelClock
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var allTerminal: Bool {
        let statuses = [nestHub, pixelClock].compactMap { $0 }
        return !statuses.isEmpty && statuses.allSatisfy(\.isTerminal)
    }

    public var anyHealthy: Bool {
        [nestHub, pixelClock].compactMap { $0 }.contains(where: \.isHealthy)
    }
}
