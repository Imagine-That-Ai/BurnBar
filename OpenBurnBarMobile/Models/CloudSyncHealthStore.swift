import Foundation
import OpenBurnBarCore
import OpenBurnBarAnalytics

public enum CloudSyncHealth: Sendable, Equatable {
    case unknown, healthy, syncing, macNotSyncing, degraded(reason: CloudErrorClassification)
    case offline, permissionDenied, appCheckBlocked, firebaseUnavailable
    /// Firestore's live network was deliberately turned off on THIS device
    /// (emergency kill switch). Distinct from every remote failure so the UI
    /// can say what is actually happening instead of rendering empty data.
    case networkDisabledOnThisDevice
    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .healthy: return "Cloud sync healthy"
        case .syncing: return "Syncing"
        case .macNotSyncing: return "Mac not syncing"
        case .degraded(let reason):
            if case .other(let message) = reason, !message.isEmpty {
                return message
            }
            return "Cloud sync degraded"
        case .offline: return "Offline"
        case .permissionDenied: return "Permission denied"
        case .appCheckBlocked: return "App Check blocked"
        case .firebaseUnavailable: return "Firebase unavailable"
        case .networkDisabledOnThisDevice: return "Cloud sync is switched off on this device (compatibility mode)"
        }
    }
    public var isHealthy: Bool { if case .healthy = self { return true }; return false }
    public var isDegraded: Bool {
        switch self {
        case .degraded, .offline, .permissionDenied, .appCheckBlocked, .firebaseUnavailable,
             .networkDisabledOnThisDevice: return true
        default: return false
        }
    }
}

@Observable @MainActor
final class CloudSyncHealthStore {
    private static let stalenessThreshold: TimeInterval = 30 * 60
    private let reader: CloudReader
    /// Whether Firestore's live network was deliberately disabled this launch
    /// (`AppDelegate.isFirestoreNetworkDisabled`). Injectable for tests.
    private let isNetworkDisabledOnThisDevice: @MainActor () -> Bool
    private let currentEpoch: @MainActor () -> MobileAuthSessionEpoch
    private var refreshGeneration = 0
    private(set) var health: CloudSyncHealth = .unknown
    private(set) var freshness: MobileSyncFreshness = .empty
    private(set) var lastPublishedAt: Date?
    private(set) var lastReadAt: Date?
    private(set) var publisher: CloudPublisherDevice?
    private(set) var isLoading = false
    private(set) var boundUid: String?

    init(
        reader: CloudReader = LiveCloudReader(),
        isNetworkDisabledOnThisDevice: @escaping @MainActor () -> Bool = { AppDelegate.isFirestoreNetworkDisabled },
        currentEpoch: @escaping @MainActor () -> MobileAuthSessionEpoch = { MobileAuthSessionEpoch(uid: nil, generation: 0) },
        scopedCaches: MobileUIDScopedCacheRegistry = .shared
    ) {
        self.reader = reader
        self.isNetworkDisabledOnThisDevice = isNetworkDisabledOnThisDevice
        self.currentEpoch = currentEpoch
        scopedCaches.register { [weak self] in self?.clearCache() }
    }

    func cancelRefresh() {
        refreshGeneration = MobileSyncOwnershipPolicy.nextGeneration(refreshGeneration)
    }

    func clearCache() {
        cancelRefresh()
        lastPublishedAt = nil
        lastReadAt = nil
        publisher = nil
        boundUid = nil
        health = .unknown
        freshness = .empty
        isLoading = false
    }

    func refresh(now: Date = Date()) async {
        // With the network off, every Firestore read silently answers from an
        // empty local cache — which used to masquerade as "$0.00 burn" and
        // "Mac last seen: never". Say what is actually going on instead.
        guard !isNetworkDisabledOnThisDevice() else {
            health = .networkDisabledOnThisDevice
            freshness = .offline
            return
        }
        refreshGeneration = MobileSyncOwnershipPolicy.nextGeneration(refreshGeneration)
        let generation = refreshGeneration
        let epoch = currentEpoch()
        isLoading = true
        health = .syncing
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        do {
            let s = try await reader.loadSyncStatus()
            guard shouldApply(generation: generation, epoch: epoch) else { return }
            lastPublishedAt = s.lastPublishedAt
            lastReadAt = s.lastReadAt
            publisher = s.publisher
            boundUid = epoch.uid
            if let c = s.lastErrorClassification {
                health = map(c)
                trackHandledError(c)
            } else if isStale(now: now) {
                health = .macNotSyncing
            } else {
                health = .healthy
            }
            freshness = freshnessForHealth(health, now: now)
        } catch let CloudGatewayError.classified(c) {
            guard shouldApply(generation: generation, epoch: epoch) else { return }
            health = map(c)
            freshness = freshnessForHealth(health, now: now)
            trackHandledError(c)
        } catch {
            guard shouldApply(generation: generation, epoch: epoch) else { return }
            health = .degraded(reason: .other(message: error.localizedDescription))
            freshness = .failed
            MobileAnalytics.shared.track(.errorHandled, [
                "error_category": "other",
                "surface": "cloud_sync"
            ])
        }
    }

    private func shouldApply(generation: Int, epoch: MobileAuthSessionEpoch) -> Bool {
        MobileSyncOwnershipPolicy.shouldApply(
            startedGeneration: generation,
            currentGeneration: refreshGeneration,
            cancelled: false
        ) && MobileAuthSessionPolicy.isCurrent(expected: epoch, current: currentEpoch())
    }

    private func freshnessForHealth(_ health: CloudSyncHealth, now: Date) -> MobileSyncFreshness {
        switch health {
        case .healthy: return .live
        case .macNotSyncing: return lastPublishedAt == nil ? .empty : .stale
        case .offline, .networkDisabledOnThisDevice: return .offline
        case .degraded, .permissionDenied, .appCheckBlocked, .firebaseUnavailable: return .failed
        case .syncing, .unknown: return lastPublishedAt == nil ? .empty : (isStale(now: now) ? .stale : .partial)
        }
    }

    /// Emit a handled-error event for a classified cloud failure. Bounded category
    /// + surface only — the raw error message is never sent.
    private func trackHandledError(_ c: CloudErrorClassification) {
        MobileAnalytics.shared.track(.errorHandled, [
            "error_category": .string(c.analyticsCode),
            "surface": "cloud_sync"
        ])
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
            // Truly never: no Mac has ever registered under this account. Give
            // the user the actual next step instead of a bare "never" — the
            // most common causes are the Mac app not running or the two
            // devices being signed into different accounts.
            return "No Mac has synced to this account yet — open OpenBurnBar on your Mac and check both devices use the same sign-in"
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
