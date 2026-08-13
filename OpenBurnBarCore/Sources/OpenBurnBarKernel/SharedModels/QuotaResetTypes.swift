import Foundation

// MARK: - Quota reset taxonomy
//
// Three user-visible kinds, plus the presentation policy that decides whether
// a detected event may take the stage, whisper (bar only), or only be written
// to the ledger. Detector input is always a *raw* snapshot — never a bucket
// that has been through `reconcilingElapsedWindow`.

public enum QuotaResetKind: String, Codable, CaseIterable, Sendable {
    case scheduled
    case surprise
    case bankedGrant
    case bankedRedeem

    public var isBanked: Bool {
        self == .bankedGrant || self == .bankedRedeem
    }
}

public enum QuotaResetWindowClass: String, Codable, CaseIterable, Sendable {
    case session
    case weekly
    case monthly
    case daily
    case other
}

public enum QuotaResetPresentation: String, Codable, CaseIterable, Sendable {
    case ignore
    case whisper
    case perform
    case ledgerOnly
}

public enum QuotaResetFreshness: String, Codable, CaseIterable, Sendable {
    case live
    case whileAway
}

public enum QuotaResetCreditSource: String, Codable, CaseIterable, Sendable {
    case promotional
    case referral
    case manual
    case unknown
}

public struct QuotaResetCredit: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let expiresAt: Date?
    public let grantedAt: Date?
    public let source: QuotaResetCreditSource

    public init(
        id: String,
        expiresAt: Date? = nil,
        grantedAt: Date? = nil,
        source: QuotaResetCreditSource = .unknown
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.grantedAt = grantedAt
        self.source = source
    }
}

public enum QuotaResetChoreography: String, Codable, CaseIterable, Sendable {
    case calendarTear
    case clockStrike
    case moonCycle
    case emberRekindle
    case plungerSlam
    case dashboardFall
    case tiboHand
    case doubleTap
    case foilCard
    case vaultFlood
    case bankerStamp
    case hourglassFlip

    public var kind: QuotaResetKind {
        switch self {
        case .calendarTear, .clockStrike, .moonCycle, .emberRekindle:
            return .scheduled
        case .plungerSlam, .dashboardFall, .tiboHand, .doubleTap:
            return .surprise
        case .foilCard, .bankerStamp:
            return .bankedGrant
        case .vaultFlood, .hourglassFlip:
            return .bankedRedeem
        }
    }
}

public struct QuotaResetCaption: Hashable, Sendable {
    public let eyebrow: String
    public let headline: String
    public let mentionsTibo: Bool

    public init(eyebrow: String, headline: String, mentionsTibo: Bool) {
        self.eyebrow = eyebrow
        self.headline = headline
        self.mentionsTibo = mentionsTibo
    }
}

public struct QuotaResetEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String { resetBoundary }

    public let providerID: ProviderID
    public let providerToken: String
    public let accountID: String
    public let accountLabel: String?
    public let bucketKey: String
    public let bucketLabel: String
    public let resetBoundary: String
    public let kind: QuotaResetKind
    public let windowClass: QuotaResetWindowClass
    public let presentation: QuotaResetPresentation
    public let freshness: QuotaResetFreshness
    public let previousUsedPercent: Double?
    public let currentUsedPercent: Double?
    public let previousLimit: Double?
    public let currentLimit: Double?
    public let previousResetsAt: Date?
    public let currentResetsAt: Date?
    public let credits: [QuotaResetCredit]
    public let observedAt: Date
    public let choreography: QuotaResetChoreography
    public let captionEyebrow: String
    public let captionHeadline: String
    public let mentionsTibo: Bool

    public init(
        providerID: ProviderID,
        providerToken: String,
        accountID: String,
        accountLabel: String?,
        bucketKey: String,
        bucketLabel: String,
        resetBoundary: String,
        kind: QuotaResetKind,
        windowClass: QuotaResetWindowClass,
        presentation: QuotaResetPresentation,
        freshness: QuotaResetFreshness,
        previousUsedPercent: Double?,
        currentUsedPercent: Double?,
        previousLimit: Double?,
        currentLimit: Double?,
        previousResetsAt: Date?,
        currentResetsAt: Date?,
        credits: [QuotaResetCredit],
        observedAt: Date,
        choreography: QuotaResetChoreography,
        captionEyebrow: String,
        captionHeadline: String,
        mentionsTibo: Bool
    ) {
        self.providerID = providerID
        self.providerToken = providerToken
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.bucketKey = bucketKey
        self.bucketLabel = bucketLabel
        self.resetBoundary = resetBoundary
        self.kind = kind
        self.windowClass = windowClass
        self.presentation = presentation
        self.freshness = freshness
        self.previousUsedPercent = previousUsedPercent
        self.currentUsedPercent = currentUsedPercent
        self.previousLimit = previousLimit
        self.currentLimit = currentLimit
        self.previousResetsAt = previousResetsAt
        self.currentResetsAt = currentResetsAt
        self.credits = credits
        self.observedAt = observedAt
        self.choreography = choreography
        self.captionEyebrow = captionEyebrow
        self.captionHeadline = captionHeadline
        self.mentionsTibo = mentionsTibo
    }

    public var isRollupAccount: Bool {
        accountID == "default" || accountID.isEmpty
    }

    public var caption: QuotaResetCaption {
        QuotaResetCaption(
            eyebrow: captionEyebrow,
            headline: captionHeadline,
            mentionsTibo: mentionsTibo
        )
    }
}

public enum QuotaResetPerformance: Hashable, Sendable {
    case single(QuotaResetEvent)
    case coalesced([QuotaResetEvent])

    public var events: [QuotaResetEvent] {
        switch self {
        case .single(let event):
            return [event]
        case .coalesced(let events):
            return events
        }
    }

    public var lead: QuotaResetEvent? { events.first }
}

public struct QuotaResetDetection: Equatable, Sendable {
    public var events: [QuotaResetEvent]
    public var consumedBoundaries: Set<String>

    public init(events: [QuotaResetEvent] = [], consumedBoundaries: Set<String> = []) {
        self.events = events
        self.consumedBoundaries = consumedBoundaries
    }

    public var isEmpty: Bool { events.isEmpty }

    public mutating func merge(_ other: QuotaResetDetection) {
        events.append(contentsOf: other.events)
        consumedBoundaries.formUnion(other.consumedBoundaries)
    }
}

public struct QuotaResetLedger: Codable, Equatable, Sendable {
    public static let maximumEvents = 50
    public static let maximumConsumedBoundaries = 200

    public var consumedBoundaries: [String]
    public var events: [QuotaResetEvent]
    public var lastCaptionByProvider: [String: String]
    public var lastSurpriseAtByProvider: [String: Date]

    public init(
        consumedBoundaries: [String] = [],
        events: [QuotaResetEvent] = [],
        lastCaptionByProvider: [String: String] = [:],
        lastSurpriseAtByProvider: [String: Date] = [:]
    ) {
        self.consumedBoundaries = consumedBoundaries
        self.events = events
        self.lastCaptionByProvider = lastCaptionByProvider
        self.lastSurpriseAtByProvider = lastSurpriseAtByProvider
    }

    public func contains(_ boundary: String) -> Bool {
        consumedBoundaries.contains(boundary)
    }

    public mutating func register(_ incoming: [QuotaResetEvent]) {
        for event in incoming {
            if !consumedBoundaries.contains(event.resetBoundary) {
                consumedBoundaries.append(event.resetBoundary)
            }
            events.removeAll { $0.resetBoundary == event.resetBoundary }
            events.append(event)
            lastCaptionByProvider[event.providerToken] = event.captionHeadline
            if event.kind == .surprise {
                lastSurpriseAtByProvider[event.providerToken] = event.observedAt
            }
        }
        if consumedBoundaries.count > Self.maximumConsumedBoundaries {
            consumedBoundaries = Array(consumedBoundaries.suffix(Self.maximumConsumedBoundaries))
        }
        if events.count > Self.maximumEvents {
            events = Array(events.suffix(Self.maximumEvents))
        }
    }

    public func latestEvent(
        providerID: ProviderID,
        accountID: String?
    ) -> QuotaResetEvent? {
        let key = QuotaResetDetector.accountKey(providerID: providerID, accountID: accountID)
        return events.reversed().first {
            $0.providerID == providerID && $0.accountID == key.accountID
        }
    }

    public func surpriseCount(
        for providerToken: String,
        within interval: TimeInterval,
        now: Date
    ) -> Int {
        events.filter {
            $0.kind == .surprise
                && $0.providerToken == providerToken
                && now.timeIntervalSince($0.observedAt) <= interval
        }.count
    }
}

public extension ProviderQuotaBucket {
    var resetWindowClass: QuotaResetWindowClass {
        if isCreditBalance || windowKind == .lifetime {
            return .other
        }
        let marker = "\(key) \(label) \(window ?? "")".lowercased()
        if windowKind == .rollingHours
            || marker.contains("5h")
            || marker.contains("5-hour")
            || marker.contains("five hour")
            || marker.contains("session") {
            return .session
        }
        if windowKind == .weekly || isWeeklyResetMarker(marker) {
            return .weekly
        }
        if windowKind == .monthly || marker.contains("month") || marker.contains("billing") {
            return .monthly
        }
        if windowKind == .daily && !marker.contains("7") {
            return .daily
        }
        if windowKind == .rollingDays {
            return isWeeklyResetMarker(marker) ? .weekly : .other
        }
        return .other
    }

    var isQuotaResetExtraLane: Bool {
        let marker = "\(key) \(label)".lowercased()
        let extras = [
            "code review",
            "codex-code-review",
            "on-demand",
            "ondemand",
            "cursor-ondemand",
            "cursor-auto",
            "auto + composer",
            "cursor-api"
        ]
        if extras.contains(where: marker.contains) {
            return true
        }
        if marker.contains("mcp") && !marker.contains("included") {
            return true
        }
        return false
    }

    var quotaUsedPercentValue: Double? {
        if let usedPercent {
            return usedPercent
        }
        if limit.isFinite, limit > 0, used.isFinite {
            return (used / limit) * 100
        }
        return nil
    }
}

private func isWeeklyResetMarker(_ marker: String) -> Bool {
    marker.contains("week")
        || marker.contains("7 day")
        || marker.contains("7-day")
        || marker.contains("7d")
        || marker.contains("seven day")
}
