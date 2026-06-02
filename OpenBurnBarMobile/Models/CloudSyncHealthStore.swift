import Foundation
import OpenBurnBarCore

public enum CloudSyncHealth: Sendable, Equatable {
    case unknown, healthy, syncing, macNotSyncing, degraded(reason: CloudErrorClassification)
    case offline, permissionDenied, appCheckBlocked, firebaseUnavailable
    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .healthy: return "Cloud sync healthy"
        case .syncing: return "Syncing"
        case .macNotSyncing: return "Mac not syncing"
        case .degraded: return "Cloud sync degraded"
        case .offline: return "Offline"
        case .permissionDenied: return "Permission denied"
        case .appCheckBlocked: return "App Check blocked"
        case .firebaseUnavailable: return "Firebase unavailable"
        }
    }
    public var isHealthy: Bool { if case .healthy = self { return true }; return false }
    public var isDegraded: Bool {
        switch self {
        case .degraded, .offline, .permissionDenied, .appCheckBlocked, .firebaseUnavailable: return true
        default: return false
        }
    }
}

@Observable @MainActor
final class CloudSyncHealthStore {
    private static let stalenessThreshold: TimeInterval = 30 * 60
    private let reader: CloudReader
    private(set) var health: CloudSyncHealth = .unknown
    private(set) var lastPublishedAt: Date?
    private(set) var lastReadAt: Date?
    private(set) var publisher: CloudPublisherDevice?
    private(set) var isLoading = false

    init(reader: CloudReader = LiveCloudReader()) { self.reader = reader }

    func refresh(now: Date = Date()) async {
        isLoading = true; health = .syncing; defer { isLoading = false }
        do {
            let s = try await reader.loadSyncStatus()
            lastPublishedAt = s.lastPublishedAt; lastReadAt = s.lastReadAt; publisher = s.publisher
            if let c = s.lastErrorClassification { health = map(c) }
            else if isStale(now: now) { health = .macNotSyncing }
            else { health = .healthy }
        }
        catch let CloudGatewayError.classified(c) { health = map(c) }
        catch { health = .degraded(reason: .other(message: error.localizedDescription)) }
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let lastPublishedAt else { return true }
        return now.timeIntervalSince(lastPublishedAt) > Self.stalenessThreshold
    }

    func statusLabel(now: Date = Date()) -> String {
        if case .macNotSyncing = health {
            return macLastSeenText(now: now)
        }
        return health.label
    }

    func macLastSeenText(now: Date = Date()) -> String {
        guard let lastSeen = publisher?.lastSeen ?? lastPublishedAt else {
            return "Mac last seen: never"
        }
        return "Mac last seen: \(Self.elapsedPhrase(since: lastSeen, now: now)) ago"
    }

    private static func elapsedPhrase(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min\(minutes == 1 ? "" : "s")"
        }

        let hours = max(1, Int((seconds / 3_600).rounded()))
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    private func map(_ c: CloudErrorClassification) -> CloudSyncHealth {
        switch c {
        case .firebaseUnavailable: return .firebaseUnavailable
        case .firestoreUnavailable: return .degraded(reason: c)
        case .appCheckBlocked: return .appCheckBlocked
        case .permissionDenied: return .permissionDenied
        case .networkUnavailable: return .offline
        default: return .degraded(reason: c)
        }
    }
}
