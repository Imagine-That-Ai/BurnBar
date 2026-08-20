import Foundation

// MARK: - Card size

/// How much room a card asks for. Resolved against the available column count
/// by `RecapDeckLayout`, so the same deck reads correctly at 3 columns on a Mac,
/// 2 on an iPad and 1 on an iPhone.
public enum RecapCardSize: String, Codable, Hashable, Sendable, CaseIterable {
    /// One column, short. Statistic tiles.
    case small
    /// One column, tall. Spotlights and rankings.
    case medium
    /// Two columns. Comparisons, timelines, editorial copy.
    case wide
    /// Full width, tall. The opener and the biggest record.
    case hero
    /// Full width, edge to edge — typography and one visual, almost no chrome.
    case fullBleed

    /// Columns this size occupies when the deck has `columns` available.
    /// Everything collapses to full width at one column; nothing ever asks for
    /// more columns than exist.
    public func columnSpan(in columns: Int) -> Int {
        let available = max(1, columns)
        switch self {
        case .small, .medium:
            return 1
        case .wide:
            return min(2, available)
        case .hero, .fullBleed:
            return available
        }
    }

    /// Relative height, in the deck's row unit. Drives the card's aspect so a
    /// row of mixed sizes still lines up.
    public var heightUnits: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .wide: return 1
        case .hero: return 2
        case .fullBleed: return 2
        }
    }

    /// Whether the size takes the full width of the deck.
    public func isFullWidth(in columns: Int) -> Bool {
        columnSpan(in: columns) >= max(1, columns)
    }
}

// MARK: - Seal state

/// Where a month sits between "still happening" and "frozen forever".
///
/// The distinction that matters: `sealedWithoutVoice` is the one frozen state a
/// re-author may touch. Without it, a user who turns the AI toggle on after the
/// 1st would see nothing change and reasonably conclude the switch is broken.
public enum RecapSealState: String, Codable, Hashable, Sendable {
    /// The month is still in progress. Regenerates freely, never notifies.
    case preview
    /// The month has ended but the recap is not final yet.
    case unsealed
    /// Frozen, with LLM-authored copy.
    case sealed
    /// Frozen, deterministic copy only. Eligible for a one-time re-author if
    /// the user later enables the editorial layer.
    case sealedWithoutVoice

    public var isSealed: Bool {
        self == .sealed || self == .sealedWithoutVoice
    }
}

// MARK: - Card

/// One rendered card: a candidate plus the copy actually being shown.
///
/// The candidate keeps its deterministic copy even after an LLM pass, so a
/// failed re-author or a rolled-back schema always has something honest to fall
/// back to.
public struct RecapCard: Codable, Hashable, Sendable, Identifiable {

    public let id: String
    public let candidate: RecapCandidate
    public let size: RecapCardSize

    /// Copy as shown — the candidate's own, or the model's if it survived the
    /// post-processor.
    public let headline: String
    public let body: String
    public let isVoiceAuthored: Bool

    public init(
        candidate: RecapCandidate,
        size: RecapCardSize,
        headline: String? = nil,
        body: String? = nil,
        isVoiceAuthored: Bool = false
    ) {
        self.id = candidate.id
        self.candidate = candidate
        self.size = size
        self.headline = headline ?? candidate.headline
        self.body = body ?? candidate.body
        self.isVoiceAuthored = isVoiceAuthored
    }

    public var kind: RecapInsightKind { candidate.kind }
    public var tone: RecapTone { candidate.tone }
    public var visual: RecapVisual { candidate.visual }
    public var visualData: RecapVisualData? { candidate.visualData }
    public var metrics: [RecapMetric] { candidate.metrics }
    public var comparison: RecapComparison? { candidate.comparison }

    /// The card's headline number, when it has one worth showing large.
    public var primaryMetric: RecapMetric? { candidate.metrics.first }

    /// Whether this card stands on its own well enough to be shared as an image.
    /// Tiny statistic tiles do not; heroes, records and spotlights do.
    public var isShareable: Bool {
        switch size {
        case .hero, .fullBleed, .wide, .medium:
            return true
        case .small:
            return candidate.kind == .record || candidate.kind == .milestone
        }
    }

    /// Returns a copy carrying model-authored prose.
    public func withVoice(headline: String, body: String) -> RecapCard {
        RecapCard(
            candidate: candidate,
            size: size,
            headline: headline,
            body: body,
            isVoiceAuthored: true
        )
    }

    /// Returns a copy at a different size — used when the model promotes a card.
    public func resized(to newSize: RecapCardSize) -> RecapCard {
        RecapCard(
            candidate: candidate,
            size: newSize,
            headline: headline,
            body: body,
            isVoiceAuthored: isVoiceAuthored
        )
    }
}

// MARK: - Recap

/// The finished deck for one month — the thing the UI renders and the store
/// persists.
public struct MonthlyRecap: Codable, Hashable, Sendable, Identifiable {

    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let window: RecapWindow
    public let generatedAt: Date

    /// "August was your builder month." Authored by the model when available,
    /// otherwise assembled deterministically from the strongest candidate.
    public let title: String
    /// Optional one-line amplification under the title.
    public let subtitle: String?

    public let cards: [RecapCard]

    /// The closing "your month in one sentence" card's text.
    public let closingSentence: String

    /// Who wrote the prose, when anyone did.
    public let provenance: InsightModelTag?
    public let isVoiceAuthored: Bool

    /// True when the underlying month could not be read in full. The deck
    /// suppresses totals and records in this state.
    public let isPartial: Bool

    public let sealState: RecapSealState

    /// Version of `RecapFacts` this deck was folded from, so a fold change can
    /// invalidate stale decks.
    public let factsSchemaVersion: Int

    public var id: String { window.key }

    public init(
        schemaVersion: Int = MonthlyRecap.currentSchemaVersion,
        window: RecapWindow,
        generatedAt: Date,
        title: String,
        subtitle: String? = nil,
        cards: [RecapCard],
        closingSentence: String,
        provenance: InsightModelTag? = nil,
        isVoiceAuthored: Bool = false,
        isPartial: Bool = false,
        sealState: RecapSealState,
        factsSchemaVersion: Int = RecapFacts.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.window = window
        self.generatedAt = generatedAt
        self.title = title
        self.subtitle = subtitle
        self.cards = cards
        self.closingSentence = closingSentence
        self.provenance = provenance
        self.isVoiceAuthored = isVoiceAuthored
        self.isPartial = isPartial
        self.sealState = sealState
        self.factsSchemaVersion = factsSchemaVersion
    }

    /// Cards worth offering a share action on.
    public var shareableCards: [RecapCard] { cards.filter(\.isShareable) }

    /// Returns a copy with new prose and seal state after a voice pass.
    public func withVoice(
        title: String,
        subtitle: String?,
        closingSentence: String,
        cards: [RecapCard],
        provenance: InsightModelTag?,
        sealState: RecapSealState
    ) -> MonthlyRecap {
        MonthlyRecap(
            schemaVersion: schemaVersion,
            window: window,
            generatedAt: generatedAt,
            title: title,
            subtitle: subtitle,
            cards: cards,
            closingSentence: closingSentence,
            provenance: provenance,
            isVoiceAuthored: true,
            isPartial: isPartial,
            sealState: sealState,
            factsSchemaVersion: factsSchemaVersion
        )
    }

    /// Returns a copy at a new seal state, leaving content untouched.
    public func sealed(as state: RecapSealState) -> MonthlyRecap {
        MonthlyRecap(
            schemaVersion: schemaVersion,
            window: window,
            generatedAt: generatedAt,
            title: title,
            subtitle: subtitle,
            cards: cards,
            closingSentence: closingSentence,
            provenance: provenance,
            isVoiceAuthored: isVoiceAuthored,
            isPartial: isPartial,
            sealState: state,
            factsSchemaVersion: factsSchemaVersion
        )
    }
}
