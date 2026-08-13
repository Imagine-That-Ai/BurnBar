import Foundation
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class QuotaResetCelebrationStore {
    static let shared = QuotaResetCelebrationStore()

    private(set) var ledger = QuotaResetLedger()
    private(set) var activePerformance: QuotaResetPerformance?
    private(set) var whisperTicks: [String: Int] = [:]
    private(set) var lastIngestedAt: Date?

    private let fileManager: FileManager
    private let ledgerURL: URL
    private var dismissTask: Task<Void, Never>?
    private var queue: [QuotaResetPerformance] = []

    var settingsProvider: () -> QuotaSettings? = { SettingsManager.shared.quotas }
    var trayVisibleProvider: () -> Bool = { false }
    var vaultVisibleProvider: () -> Bool = { false }
    var presentJewel: ((QuotaResetPerformance) -> Void)?
    var dismissJewel: (() -> Void)?
    var announce: ((String) -> Void)?
    var notify: ((QuotaResetEvent) -> Void)?

    init(
        appPaths: OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.ledgerURL = appPaths.providerQuotaResetLedgerURL
        self.ledger = Self.loadLedger(from: ledgerURL, fileManager: fileManager)
    }

    var activeEvent: QuotaResetEvent? { activePerformance?.lead }

    func latestEvent(for snapshot: ProviderQuotaSnapshot) -> QuotaResetEvent? {
        ledger.latestEvent(providerID: snapshot.providerID, accountID: snapshot.accountID)
    }

    func ingest(_ detection: QuotaResetDetection, now: Date = Date()) {
        lastIngestedAt = now
        let allowed = QuotaResetDetector.deduplicate(detection.events).filter { event in
            guard event.presentation != .ignore else { return false }
            return settingsProvider()?.allowsCelebration(of: event.kind) ?? true
        }
        guard !allowed.isEmpty else { return }

        ledger.register(allowed)
        persistLedger()

        for event in allowed where event.presentation == .whisper {
            whisperTicks[event.resetBoundary, default: 0] += 1
        }

        let performances = QuotaResetDetector.performances(from: allowed)
        guard !performances.isEmpty else { return }
        queue.append(contentsOf: performances)
        if activePerformance == nil {
            playNext()
        }
    }

    func replay(_ event: QuotaResetEvent) {
        queue.insert(.single(event), at: 0)
        if activePerformance == nil {
            playNext()
        } else {
            dismissCurrent()
            playNext()
        }
    }

    func playSample(kind: QuotaResetKind, provider: AgentProvider) {
        let now = Date()
        let seed = "sample|\(kind.rawValue)|\(provider.persistedToken)|\(Int(now.timeIntervalSince1970))"
        let caption = QuotaResetCopy.caption(
            kind: kind,
            providerToken: provider.persistedToken,
            providerDisplayName: provider.displayName,
            windowClass: .weekly,
            accountLabel: nil,
            surpriseCountLastDay: kind == .surprise ? 1 : 0,
            lastHeadline: ledger.lastCaptionByProvider[provider.persistedToken],
            seed: seed
        )
        let event = QuotaResetEvent(
            providerID: provider.providerID,
            providerToken: provider.persistedToken,
            accountID: "default",
            accountLabel: nil,
            bucketKey: "sample",
            bucketLabel: "Weekly quota",
            resetBoundary: seed,
            kind: kind,
            windowClass: .weekly,
            presentation: .perform,
            freshness: .live,
            previousUsedPercent: 86,
            currentUsedPercent: 2,
            previousLimit: 100,
            currentLimit: 100,
            previousResetsAt: now.addingTimeInterval(kind == .surprise ? 3 * 86_400 : -120),
            currentResetsAt: now.addingTimeInterval(7 * 86_400),
            credits: kind.isBanked ? [QuotaResetCredit(id: "sample-card", expiresAt: now.addingTimeInterval(20 * 86_400))] : [],
            observedAt: now,
            choreography: QuotaResetCopy.choreography(
                kind: kind,
                providerToken: provider.persistedToken,
                surpriseCountLastDay: kind == .surprise ? 1 : 0,
                lastHeadline: nil,
                seed: seed
            ),
            captionEyebrow: caption.eyebrow,
            captionHeadline: caption.headline,
            mentionsTibo: caption.mentionsTibo
        )
        replay(event)
    }

    func dismissCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
        activePerformance = nil
        dismissJewel?()
    }

    var prefersJewel: Bool {
        !trayVisibleProvider() && !vaultVisibleProvider()
    }

    func duration(for performance: QuotaResetPerformance) -> TimeInterval {
        if case .coalesced = performance { return 3.6 }
        switch performance.lead?.kind {
        case .scheduled: return 2.8
        case .bankedGrant: return 3.2
        case .bankedRedeem: return 4.0
        case .surprise:
            return performance.lead?.choreography == .doubleTap ? 5.2 : 4.6
        case .none:
            return 2.8
        }
    }

    private func playNext() {
        guard activePerformance == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        activePerformance = next
        announce?(announcement(for: next))
        if let lead = next.lead {
            Analytics.shared.track(.quotaResetCelebrated, [
                "provider_name": .string(lead.providerToken),
                "kind": .string(lead.kind.rawValue),
                "choreography": .string(lead.choreography.rawValue)
            ])
            if prefersJewel {
                presentJewel?(next)
            }
            if shouldNotify(lead) {
                notify?(lead)
            }
        }
        let wait = duration(for: next) + 0.4
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
            self?.playNext()
        }
    }

    private func shouldNotify(_ event: QuotaResetEvent) -> Bool {
        guard prefersJewel else { return false }
        return event.kind == .surprise || event.kind.isBanked
    }

    private func announcement(for performance: QuotaResetPerformance) -> String {
        if case .coalesced(let events) = performance {
            return QuotaResetCopy.coalescedCaption(providers: events.map(\.providerToken)).headline
        }
        return performance.lead?.captionHeadline ?? "Quota reset"
    }

    private func persistLedger() {
        do {
            let parent = ledgerURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("QuotaResetCelebrationStore: persist failed", error: error)
        }
    }

    private static func loadLedger(from url: URL, fileManager: FileManager) -> QuotaResetLedger {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return QuotaResetLedger()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(QuotaResetLedger.self, from: data)) ?? QuotaResetLedger()
    }
}
