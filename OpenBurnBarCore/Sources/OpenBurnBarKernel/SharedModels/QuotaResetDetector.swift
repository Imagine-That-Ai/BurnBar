import Foundation

public enum QuotaResetDetector {
    public static let surpriseHorizon: TimeInterval = 6 * 60 * 60
    public static let scheduledImminentHorizon: TimeInterval = 2 * 60 * 60
    public static let materialUsedPercentDrop: Double = 25
    public static let materialUsedPercentCeiling: Double = 40
    public static let largeUsedPercentDrop: Double = 50
    public static let materialAbsoluteUsedFraction: Double = 0.25
    public static let limitStabilityTolerance: Double = 0.01
    public static let liveObservationGrace: TimeInterval = 15 * 60
    public static let performanceFreshnessWindow: TimeInterval = 36 * 60 * 60
    public static let doubleTapWindow: TimeInterval = 24 * 60 * 60

    public struct AccountKey: Hashable, Sendable {
        public let providerID: ProviderID
        public let accountID: String

        public var storageKey: String { "\(providerID.rawValue):\(accountID)" }
    }

    public static func accountKey(providerID: ProviderID, accountID: String?) -> AccountKey {
        let trimmed = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AccountKey(
            providerID: providerID,
            accountID: trimmed.isEmpty ? "default" : trimmed
        )
    }

    public static func accountKey(for snapshot: ProviderQuotaSnapshot) -> AccountKey {
        accountKey(providerID: snapshot.providerID, accountID: snapshot.accountID)
    }

    public static func detect(
        previous: ProviderQuotaSnapshot?,
        current: ProviderQuotaSnapshot,
        now: Date,
        consumedBoundaries: Set<String> = [],
        appWasActive: Bool = true,
        previousCredits: [QuotaResetCredit]? = nil,
        currentCredits: [QuotaResetCredit]? = nil,
        lastCaptionByProvider: [String: String] = [:],
        surpriseCountLastDay: Int = 0
    ) -> QuotaResetDetection {
        guard let previous else { return QuotaResetDetection() }
        guard isExactSnapshot(current) else { return QuotaResetDetection() }

        let previousInventory = previousCredits ?? previous.resetCredits
        let currentInventory = currentCredits ?? current.resetCredits
        let key = accountKey(for: current)
        let providerToken = current.quotaProvider?.persistedToken ?? current.provider.lowercased()

        var candidates: [QuotaResetEvent] = []

        if let grant = bankedInventoryEvent(
            previous: previous,
            current: current,
            previousCredits: previousInventory,
            currentCredits: currentInventory,
            now: now,
            appWasActive: appWasActive,
            consumedBoundaries: consumedBoundaries,
            lastCaption: lastCaptionByProvider[providerToken],
            surpriseCountLastDay: surpriseCountLastDay,
            usedDropped: false
        ) {
            candidates.append(grant)
        }

        let previousByKey = Dictionary(uniqueKeysWithValues: previous.buckets.map { ($0.key, $0) })
        var usedDroppedOnPerformableWindow = false

        for bucket in current.buckets {
            guard let prior = previousByKey[bucket.key] else { continue }
            guard !bucket.isQuotaResetExtraLane, !prior.isQuotaResetExtraLane else { continue }
            guard bucket.isDisplayableQuotaSignal || prior.isDisplayableQuotaSignal else { continue }

            let windowClass = bucket.resetWindowClass
            let usedDropped = isMaterialUsedDrop(previous: prior, current: bucket)
            if usedDropped && isPerformableWindow(windowClass) {
                usedDroppedOnPerformableWindow = true
            }

            guard usedDropped else { continue }
            guard !isLimitIncreaseWithoutBurnDrop(previous: prior, current: bucket) else { continue }

            let kind = classifyUsedDrop(
                previous: prior,
                current: bucket,
                now: now,
                previousCredits: previousInventory,
                currentCredits: currentInventory
            )
            let freshness = observationFreshness(
                previousResetsAt: prior.resetsAt,
                now: now,
                appWasActive: appWasActive
            )
            let presentation = presentation(
                kind: kind,
                windowClass: windowClass,
                freshness: freshness,
                age: prior.resetsAt.map { now.timeIntervalSince($0) }
            )
            guard presentation != .ignore else { continue }

            let boundary = resetBoundary(
                kind: kind,
                providerID: current.providerID,
                accountID: key.accountID,
                bucketKey: bucket.key,
                previousResetsAt: prior.resetsAt,
                currentResetsAt: bucket.resetsAt,
                now: now,
                creditID: redeemedCreditID(previous: previousInventory, current: currentInventory)
            )
            guard !consumedBoundaries.contains(boundary) else { continue }

            candidates.append(
                makeEvent(
                    snapshot: current,
                    bucket: bucket,
                    previous: prior,
                    kind: kind,
                    windowClass: windowClass,
                    presentation: presentation,
                    freshness: freshness,
                    boundary: boundary,
                    credits: currentInventory,
                    now: now,
                    lastCaption: lastCaptionByProvider[providerToken],
                    surpriseCountLastDay: surpriseCountLastDay
                )
            )
        }

        if usedDroppedOnPerformableWindow,
           let redeem = bankedInventoryEvent(
                previous: previous,
                current: current,
                previousCredits: previousInventory,
                currentCredits: currentInventory,
                now: now,
                appWasActive: appWasActive,
                consumedBoundaries: consumedBoundaries,
                lastCaption: lastCaptionByProvider[providerToken],
                surpriseCountLastDay: surpriseCountLastDay,
                usedDropped: true
           ) {
            candidates.append(redeem)
        }

        let reduced = reduceToLeadingEvents(candidates)
        return QuotaResetDetection(
            events: reduced,
            consumedBoundaries: Set(reduced.map(\.resetBoundary))
        )
    }

    public static func detectClockCross(
        snapshot: ProviderQuotaSnapshot,
        now: Date,
        consumedBoundaries: Set<String> = [],
        appWasActive: Bool = true,
        lastCaptionByProvider: [String: String] = [:]
    ) -> QuotaResetDetection {
        guard isExactSnapshot(snapshot) else { return QuotaResetDetection() }
        let key = accountKey(for: snapshot)
        let providerToken = snapshot.quotaProvider?.persistedToken ?? snapshot.provider.lowercased()
        var events: [QuotaResetEvent] = []

        for bucket in snapshot.buckets {
            guard let resetsAt = bucket.resetsAt, resetsAt <= now else { continue }
            guard bucket.isDisplayableQuotaSignal else { continue }
            guard !bucket.isQuotaResetExtraLane else { continue }
            let windowClass = bucket.resetWindowClass
            let age = now.timeIntervalSince(resetsAt)
            let freshness: QuotaResetFreshness = (!appWasActive || age > liveObservationGrace) ? .whileAway : .live
            let presentation = presentation(
                kind: .scheduled,
                windowClass: windowClass,
                freshness: freshness,
                age: age
            )
            guard presentation != .ignore else { continue }
            let boundary = resetBoundary(
                kind: .scheduled,
                providerID: snapshot.providerID,
                accountID: key.accountID,
                bucketKey: bucket.key,
                previousResetsAt: resetsAt,
                currentResetsAt: bucket.resetsAt,
                now: now,
                creditID: nil
            )
            guard !consumedBoundaries.contains(boundary) else { continue }
            events.append(
                makeEvent(
                    snapshot: snapshot,
                    bucket: bucket,
                    previous: bucket,
                    kind: .scheduled,
                    windowClass: windowClass,
                    presentation: presentation,
                    freshness: freshness,
                    boundary: boundary,
                    credits: snapshot.resetCredits,
                    now: now,
                    lastCaption: lastCaptionByProvider[providerToken],
                    surpriseCountLastDay: 0
                )
            )
        }

        let reduced = reduceToLeadingEvents(events)
        return QuotaResetDetection(
            events: reduced,
            consumedBoundaries: Set(reduced.map(\.resetBoundary))
        )
    }

    public static func deduplicate(_ events: [QuotaResetEvent]) -> [QuotaResetEvent] {
        var kept: [QuotaResetEvent] = []
        var seen = Set<String>()
        let accountEvents = events.filter { !$0.isRollupAccount }
        let rollups = events.filter(\.isRollupAccount)

        for event in accountEvents + rollups {
            let signature = "\(event.providerID.rawValue)|\(event.bucketKey)|\(event.kind.rawValue)|\(event.previousResetsAt?.timeIntervalSince1970 ?? 0)"
            if event.isRollupAccount,
               accountEvents.contains(where: {
                   $0.providerID == event.providerID
                       && $0.bucketKey == event.bucketKey
                       && $0.kind == event.kind
               }) {
                continue
            }
            if seen.contains(event.resetBoundary) || seen.contains(signature) {
                continue
            }
            seen.insert(event.resetBoundary)
            seen.insert(signature)
            kept.append(event)
        }
        return kept
    }

    public static func performances(from events: [QuotaResetEvent]) -> [QuotaResetPerformance] {
        let performable = events.filter { $0.presentation == .perform }
        let surprises = performable.filter { $0.kind == .surprise }
        let redeems = performable.filter { $0.kind == .bankedRedeem }
        let grants = performable.filter { $0.kind == .bankedGrant }
        let scheduled = performable.filter { $0.kind == .scheduled }

        var result: [QuotaResetPerformance] = []
        result.append(contentsOf: surprises.map(QuotaResetPerformance.single))
        result.append(contentsOf: redeems.map(QuotaResetPerformance.single))
        result.append(contentsOf: grants.map(QuotaResetPerformance.single))
        if scheduled.count >= 2 {
            result.append(.coalesced(scheduled))
        } else {
            result.append(contentsOf: scheduled.map(QuotaResetPerformance.single))
        }
        return result
    }

    // MARK: - Classification

    static func classifyUsedDrop(
        previous: ProviderQuotaBucket,
        current: ProviderQuotaBucket,
        now: Date,
        previousCredits: [QuotaResetCredit],
        currentCredits: [QuotaResetCredit]
    ) -> QuotaResetKind {
        let redeemed = redeemedCreditID(previous: previousCredits, current: currentCredits)
        if redeemed != nil {
            return .bankedRedeem
        }
        if let previousReset = previous.resetsAt, previousReset.timeIntervalSince(now) >= surpriseHorizon {
            return .surprise
        }
        return .scheduled
    }

    static func isMaterialUsedDrop(previous: ProviderQuotaBucket, current: ProviderQuotaBucket) -> Bool {
        if isLimitIncreaseWithoutBurnDrop(previous: previous, current: current) {
            return false
        }
        if let previousPercent = previous.quotaUsedPercentValue,
           let currentPercent = current.quotaUsedPercentValue {
            let drop = previousPercent - currentPercent
            if drop >= materialUsedPercentDrop
                && limitsAreStable(previous.limit, current.limit)
                && (currentPercent <= materialUsedPercentCeiling || drop >= largeUsedPercentDrop) {
                return true
            }
        }
        if previous.limit.isFinite, previous.limit > 0 {
            let absoluteDrop = previous.used - current.used
            if absoluteDrop >= previous.limit * materialAbsoluteUsedFraction {
                return true
            }
        }
        return false
    }

    static func isLimitIncreaseWithoutBurnDrop(
        previous: ProviderQuotaBucket,
        current: ProviderQuotaBucket
    ) -> Bool {
        guard previous.limit.isFinite, current.limit.isFinite,
              previous.limit > 0, current.limit > previous.limit * (1 + limitStabilityTolerance)
        else {
            return false
        }
        let usedDelta = abs(previous.used - current.used)
        let usedTolerance = max(1, previous.limit * limitStabilityTolerance)
        return usedDelta <= usedTolerance
    }

    static func limitsAreStable(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return true }
        if lhs <= 0 || rhs <= 0 { return true }
        return abs(lhs - rhs) / max(lhs, rhs) <= limitStabilityTolerance
    }

    static func isExactSnapshot(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        snapshot.confidence == .high
    }

    public static func isPerformableWindow(_ windowClass: QuotaResetWindowClass) -> Bool {
        switch windowClass {
        case .weekly, .monthly, .daily:
            return true
        case .session, .other:
            return false
        }
    }

    static func presentation(
        kind: QuotaResetKind,
        windowClass: QuotaResetWindowClass,
        freshness _: QuotaResetFreshness,
        age: TimeInterval?
    ) -> QuotaResetPresentation {
        if let age, age > performanceFreshnessWindow, kind == .scheduled {
            return isPerformableWindow(windowClass) ? .ledgerOnly : .ignore
        }
        switch windowClass {
        case .session:
            return kind == .surprise ? .whisper : .whisper
        case .other:
            return .ignore
        case .weekly, .monthly, .daily:
            switch kind {
            case .scheduled, .surprise, .bankedGrant, .bankedRedeem:
                return .perform
            }
        }
    }

    static func observationFreshness(
        previousResetsAt: Date?,
        now: Date,
        appWasActive: Bool
    ) -> QuotaResetFreshness {
        guard appWasActive else { return .whileAway }
        if let previousResetsAt, now.timeIntervalSince(previousResetsAt) > liveObservationGrace,
           previousResetsAt <= now {
            return .whileAway
        }
        return .live
    }

    static func resetBoundary(
        kind: QuotaResetKind,
        providerID: ProviderID,
        accountID: String,
        bucketKey: String,
        previousResetsAt: Date?,
        currentResetsAt: Date?,
        now: Date,
        creditID: String?
    ) -> String {
        switch kind {
        case .scheduled:
            let elapsed = previousResetsAt ?? now
            return "scheduled|\(providerID.rawValue)|\(accountID)|\(bucketKey)|\(Int(elapsed.timeIntervalSince1970))"
        case .surprise:
            let previous = Int(previousResetsAt?.timeIntervalSince1970 ?? 0)
            let current = Int(currentResetsAt?.timeIntervalSince1970 ?? 0)
            let day = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
            return "surprise|\(providerID.rawValue)|\(accountID)|\(bucketKey)|\(previous)|\(current)|\(day)"
        case .bankedGrant, .bankedRedeem:
            let credit = creditID ?? "unknown"
            return "\(kind.rawValue)|\(providerID.rawValue)|\(accountID)|\(credit)"
        }
    }

    static func redeemedCreditID(
        previous: [QuotaResetCredit],
        current: [QuotaResetCredit]
    ) -> String? {
        let currentIDs = Set(current.map(\.id))
        return previous.first { !currentIDs.contains($0.id) }?.id
    }

    static func grantedCredits(
        previous: [QuotaResetCredit],
        current: [QuotaResetCredit]
    ) -> [QuotaResetCredit] {
        let previousIDs = Set(previous.map(\.id))
        return current.filter { !previousIDs.contains($0.id) }
    }

    private static func bankedInventoryEvent(
        previous: ProviderQuotaSnapshot,
        current: ProviderQuotaSnapshot,
        previousCredits: [QuotaResetCredit],
        currentCredits: [QuotaResetCredit],
        now: Date,
        appWasActive: Bool,
        consumedBoundaries: Set<String>,
        lastCaption: String?,
        surpriseCountLastDay: Int,
        usedDropped: Bool
    ) -> QuotaResetEvent? {
        if usedDropped {
            guard let redeemed = redeemedCreditID(previous: previousCredits, current: currentCredits) else {
                return nil
            }
            return makeBankedEvent(
                snapshot: current,
                kind: .bankedRedeem,
                creditID: redeemed,
                credits: currentCredits,
                now: now,
                appWasActive: appWasActive,
                consumedBoundaries: consumedBoundaries,
                lastCaption: lastCaption,
                surpriseCountLastDay: surpriseCountLastDay,
                previous: previous
            )
        }

        let granted = grantedCredits(previous: previousCredits, current: currentCredits)
        guard let credit = granted.first else { return nil }
        return makeBankedEvent(
            snapshot: current,
            kind: .bankedGrant,
            creditID: credit.id,
            credits: currentCredits,
            now: now,
            appWasActive: appWasActive,
            consumedBoundaries: consumedBoundaries,
            lastCaption: lastCaption,
            surpriseCountLastDay: surpriseCountLastDay,
            previous: previous
        )
    }

    private static func makeBankedEvent(
        snapshot: ProviderQuotaSnapshot,
        kind: QuotaResetKind,
        creditID: String,
        credits: [QuotaResetCredit],
        now: Date,
        appWasActive: Bool,
        consumedBoundaries: Set<String>,
        lastCaption: String?,
        surpriseCountLastDay: Int,
        previous: ProviderQuotaSnapshot
    ) -> QuotaResetEvent? {
        let key = accountKey(for: snapshot)
        let bucket = performableBucket(in: snapshot) ?? snapshot.buckets.first
        guard let bucket else { return nil }
        let windowClass = isPerformableWindow(bucket.resetWindowClass) ? bucket.resetWindowClass : .weekly
        let freshness: QuotaResetFreshness = appWasActive ? .live : .whileAway
        let presentation = presentation(
            kind: kind,
            windowClass: windowClass,
            freshness: freshness,
            age: nil
        )
        let boundary = resetBoundary(
            kind: kind,
            providerID: snapshot.providerID,
            accountID: key.accountID,
            bucketKey: bucket.key,
            previousResetsAt: bucket.resetsAt,
            currentResetsAt: bucket.resetsAt,
            now: now,
            creditID: creditID
        )
        guard !consumedBoundaries.contains(boundary) else { return nil }
        let prior = previous.buckets.first(where: { $0.key == bucket.key }) ?? bucket
        return makeEvent(
            snapshot: snapshot,
            bucket: bucket,
            previous: prior,
            kind: kind,
            windowClass: windowClass,
            presentation: presentation,
            freshness: freshness,
            boundary: boundary,
            credits: credits,
            now: now,
            lastCaption: lastCaption,
            surpriseCountLastDay: surpriseCountLastDay
        )
    }

    private static func performableBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { isPerformableWindow($0.resetWindowClass) && !$0.isQuotaResetExtraLane }
    }

    private static func reduceToLeadingEvents(_ events: [QuotaResetEvent]) -> [QuotaResetEvent] {
        guard events.count > 1 else { return events }
        let grouped = Dictionary(grouping: events) { event in
            "\(event.providerID.rawValue)|\(event.accountID)|\(event.kind.rawValue)"
        }
        return grouped.values.compactMap { group in
            group.min { lhs, rhs in
                let lhsRank = windowRank(lhs.windowClass)
                let rhsRank = windowRank(rhs.windowClass)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return kindRank(lhs.kind) < kindRank(rhs.kind)
            }
        }
        .sorted { kindRank($0.kind) < kindRank($1.kind) }
    }

    private static func windowRank(_ windowClass: QuotaResetWindowClass) -> Int {
        switch windowClass {
        case .weekly: return 0
        case .monthly: return 1
        case .daily: return 2
        case .session: return 3
        case .other: return 4
        }
    }

    private static func kindRank(_ kind: QuotaResetKind) -> Int {
        switch kind {
        case .surprise: return 0
        case .bankedRedeem: return 1
        case .bankedGrant: return 2
        case .scheduled: return 3
        }
    }

    private static func makeEvent(
        snapshot: ProviderQuotaSnapshot,
        bucket: ProviderQuotaBucket,
        previous: ProviderQuotaBucket,
        kind: QuotaResetKind,
        windowClass: QuotaResetWindowClass,
        presentation: QuotaResetPresentation,
        freshness: QuotaResetFreshness,
        boundary: String,
        credits: [QuotaResetCredit],
        now: Date,
        lastCaption: String?,
        surpriseCountLastDay: Int
    ) -> QuotaResetEvent {
        let key = accountKey(for: snapshot)
        let providerToken = snapshot.quotaProvider?.persistedToken ?? snapshot.provider.lowercased()
        let caption = QuotaResetCopy.caption(
            kind: kind,
            providerToken: providerToken,
            providerDisplayName: snapshot.quotaProvider?.displayName ?? snapshot.provider,
            windowClass: windowClass,
            accountLabel: snapshot.accountLabel,
            surpriseCountLastDay: surpriseCountLastDay,
            lastHeadline: lastCaption,
            seed: boundary
        )
        let choreography = QuotaResetCopy.choreography(
            kind: kind,
            providerToken: providerToken,
            surpriseCountLastDay: surpriseCountLastDay,
            lastHeadline: lastCaption,
            seed: boundary
        )
        return QuotaResetEvent(
            providerID: snapshot.providerID,
            providerToken: providerToken,
            accountID: key.accountID,
            accountLabel: snapshot.accountLabel,
            bucketKey: bucket.key,
            bucketLabel: bucket.label,
            resetBoundary: boundary,
            kind: kind,
            windowClass: windowClass,
            presentation: presentation,
            freshness: freshness,
            previousUsedPercent: previous.quotaUsedPercentValue,
            currentUsedPercent: bucket.quotaUsedPercentValue,
            previousLimit: previous.limit.isFinite ? previous.limit : nil,
            currentLimit: bucket.limit.isFinite ? bucket.limit : nil,
            previousResetsAt: previous.resetsAt,
            currentResetsAt: bucket.resetsAt,
            credits: credits,
            observedAt: now,
            choreography: choreography,
            captionEyebrow: caption.eyebrow,
            captionHeadline: caption.headline,
            mentionsTibo: caption.mentionsTibo
        )
    }
}
