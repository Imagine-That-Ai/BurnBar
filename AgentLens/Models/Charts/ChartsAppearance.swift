import SwiftUI

// MARK: - Charts Appearance
//
// The user's visual contract with the Charts page: which palette mood the
// gallery wears, how dense the cards pack, how wide the grid runs, whether
// the hero and burn charts speak in dollars or tokens, and any per-card
// accent overrides. Persisted as JSON under `ChartsAppearance.storageKey`
// with the same forward-compatible decode discipline as `ChartsPageLayout` —
// unknown enum cases and out-of-range values fall back to defaults, never to
// a blank page.
//
// Every mood color is `Color.adaptive`, so moods stay coherent across the
// Moon Lit / Sun Lit skins and light/dark appearances exactly like the
// design-system tokens do.

// MARK: Palette mood

/// A named color story for the gallery. Moods re-point the six accent slots;
/// charts never name a raw color, only the slot they speak in.
enum ChartsPaletteMood: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The signature OpenBurnBar warm spectrum (the current look).
    case ember
    /// Cool blues and teals — deep water.
    case ocean
    /// Violets and magentas — neon dusk.
    case orchid
    /// Greens and limes — bright field.
    case meadow
    /// Silver-on-silver ink — the quiet instrument.
    case monochrome

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ember: return "Ember"
        case .ocean: return "Ocean"
        case .orchid: return "Orchid"
        case .meadow: return "Meadow"
        case .monochrome: return "Monochrome"
        }
    }

    /// One-line gallery label for the picker.
    var tagline: String {
        switch self {
        case .ember: return "The signature warm spectrum"
        case .ocean: return "Deep water, cool light"
        case .orchid: return "Neon dusk, violet hour"
        case .meadow: return "Bright field, spring ink"
        case .monochrome: return "One silver voice"
        }
    }

    /// The two colors the picker swatch renders as a gradient.
    var swatch: [Color] {
        [color(for: .burn), color(for: .mix)]
    }

    /// Resolves an accent slot to a concrete, adaptive color in this mood.
    func color(for slot: ChartsAccentSlot) -> Color {
        switch self {
        case .ember:
            // The canonical design-system tokens — pixel-identical to the
            // pre-mood gallery.
            switch slot {
            case .burn: return DesignSystem.Colors.ember
            case .mix: return DesignSystem.Colors.whimsy
            case .cache: return DesignSystem.Colors.success
            case .reasoning: return DesignSystem.Colors.blaze
            case .rhythm: return DesignSystem.Colors.amber
            case .delta: return DesignSystem.Colors.amber
            }
        case .ocean:
            switch slot {
            case .burn: return Color.adaptive(light: "2563EB", dark: "60A5FA")
            case .mix: return Color.adaptive(light: "0E7490", dark: "22D3EE")
            case .cache: return Color.adaptive(light: "0F766E", dark: "2DD4BF")
            case .reasoning: return Color.adaptive(light: "1D4ED8", dark: "93C5FD")
            case .rhythm: return Color.adaptive(light: "0369A1", dark: "38BDF8")
            case .delta: return Color.adaptive(light: "0891B2", dark: "67E8F9")
            }
        case .orchid:
            switch slot {
            case .burn: return Color.adaptive(light: "A855F7", dark: "C084FC")
            case .mix: return Color.adaptive(light: "7C3AED", dark: "A78BFA")
            case .cache: return Color.adaptive(light: "059669", dark: "34D399")
            case .reasoning: return Color.adaptive(light: "DB2777", dark: "F472B6")
            case .rhythm: return Color.adaptive(light: "C026D3", dark: "E879F9")
            case .delta: return Color.adaptive(light: "9333EA", dark: "D8B4FE")
            }
        case .meadow:
            switch slot {
            case .burn: return Color.adaptive(light: "16A34A", dark: "4ADE80")
            case .mix: return Color.adaptive(light: "0D9488", dark: "2DD4BF")
            case .cache: return Color.adaptive(light: "15803D", dark: "86EFAC")
            case .reasoning: return Color.adaptive(light: "65A30D", dark: "A3E635")
            case .rhythm: return Color.adaptive(light: "CA8A04", dark: "FACC15")
            case .delta: return Color.adaptive(light: "059669", dark: "6EE7B7")
            }
        case .monochrome:
            // One voice, six volumes — the ChartInk philosophy taken page-wide.
            switch slot {
            case .burn: return DesignSystem.Colors.textPrimary
            case .mix: return DesignSystem.Colors.textPrimary.opacity(0.72)
            case .cache: return DesignSystem.Colors.textSecondary
            case .reasoning: return DesignSystem.Colors.textPrimary.opacity(0.55)
            case .rhythm: return DesignSystem.Colors.textMuted
            case .delta: return DesignSystem.Colors.textSecondary.opacity(0.8)
            }
        }
    }
}

// MARK: Accent slot

/// The six voices a chart can speak in. Charts are assigned a default slot
/// from their semantics (spend → burn, mixes → mix, …); users can re-voice
/// any single card via an override.
enum ChartsAccentSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case burn
    case mix
    case cache
    case reasoning
    case rhythm
    case delta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .burn: return "Burn"
        case .mix: return "Mix"
        case .cache: return "Cache"
        case .reasoning: return "Reasoning"
        case .rhythm: return "Rhythm"
        case .delta: return "Delta"
        }
    }
}

extension ChartKind {
    /// The accent slot this chart speaks in by default — same assignments as
    /// the original hard-coded accents.
    var defaultAccentSlot: ChartsAccentSlot {
        switch self {
        case .burnOverTime, .burnForecast, .costPerSessionDistribution, .sessionOutliers:
            return .burn
        case .providerMix, .modelMix, .modelConcentration, .projectFocus, .remoteVsLocal:
            return .mix
        case .cacheROI, .provenanceQuality:
            return .cache
        case .reasoningShare:
            return .reasoning
        case .hourOfDayHeatmap:
            return .rhythm
        case .weekOverWeekDelta:
            return .delta
        }
    }
}

// MARK: Density

/// Card vertical rhythm. Comfortable is the gallery default; compact packs
/// more gallery onto one screen for the heads-down operator.
enum ChartsDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// Height of the chart body inside a card.
    var chartHeight: CGFloat {
        switch self {
        case .comfortable: return 190
        case .compact: return 128
        }
    }
}

// MARK: Primary metric

/// The unit the hero counter and the burn-family charts speak in.
enum ChartsPrimaryMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case cost
    case tokens

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cost: return value.formatAsCost()
        case .tokens: return Int(value.rounded()).formatAsTokenVolume()
        }
    }
}

// MARK: - Appearance model

struct ChartsAppearance: Codable, Equatable, Sendable {
    static let storageKey = "chartsPageAppearance.v1"

    /// Supported grid widths, in columns.
    static let columnRange = 2...3

    var paletteMood: ChartsPaletteMood
    var density: ChartsDensity
    var columns: Int
    var primaryMetric: ChartsPrimaryMetric
    /// `ChartKind.rawValue` → `ChartsAccentSlot.rawValue`.
    var accentOverrides: [String: String]

    static var `default`: ChartsAppearance {
        ChartsAppearance(
            paletteMood: .ember,
            density: .comfortable,
            columns: 2,
            primaryMetric: .cost,
            accentOverrides: [:]
        )
    }

    init(
        paletteMood: ChartsPaletteMood = .ember,
        density: ChartsDensity = .comfortable,
        columns: Int = 2,
        primaryMetric: ChartsPrimaryMetric = .cost,
        accentOverrides: [String: String] = [:]
    ) {
        self.paletteMood = paletteMood
        self.density = density
        self.columns = min(Self.columnRange.upperBound, max(Self.columnRange.lowerBound, columns))
        self.primaryMetric = primaryMetric
        // Keep only overrides that still name a real chart and a real slot,
        // and that actually differ from the chart's default voice.
        self.accentOverrides = accentOverrides.reduce(into: [:]) { result, entry in
            guard let kind = ChartKind(rawValue: entry.key),
                  let slot = ChartsAccentSlot(rawValue: entry.value),
                  slot != kind.defaultAccentSlot else { return }
            result[entry.key] = entry.value
        }
    }

    // MARK: Accent resolution

    /// The color a chart renders in: override slot when present, else its
    /// default slot, always through the active mood.
    func accent(for kind: ChartKind) -> Color {
        paletteMood.color(for: slot(for: kind))
    }

    func slot(for kind: ChartKind) -> ChartsAccentSlot {
        guard let raw = accentOverrides[kind.rawValue],
              let slot = ChartsAccentSlot(rawValue: raw) else {
            return kind.defaultAccentSlot
        }
        return slot
    }

    // MARK: Mutations

    mutating func setColumns(_ count: Int) {
        columns = min(Self.columnRange.upperBound, max(Self.columnRange.lowerBound, count))
    }

    /// Re-voices one chart. Passing the chart's default slot clears the
    /// override instead of storing a redundant entry.
    mutating func setAccentSlot(_ slot: ChartsAccentSlot, for kind: ChartKind) {
        if slot == kind.defaultAccentSlot {
            accentOverrides.removeValue(forKey: kind.rawValue)
        } else {
            accentOverrides[kind.rawValue] = slot.rawValue
        }
    }

    mutating func reset() {
        self = .default
    }

    // MARK: Persistence

    /// Tolerant JSON round-trip: unknown enum cases, wrong types, and
    /// garbage all fall back to defaults rather than failing the page.
    static func decode(from data: Data) -> ChartsAppearance {
        struct Raw: Codable {
            let paletteMood: String?
            let density: String?
            let columns: Int?
            let primaryMetric: String?
            let accentOverrides: [String: String]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return .default
        }
        return ChartsAppearance(
            paletteMood: raw.paletteMood.flatMap(ChartsPaletteMood.init(rawValue:)) ?? .ember,
            density: raw.density.flatMap(ChartsDensity.init(rawValue:)) ?? .comfortable,
            columns: raw.columns ?? 2,
            primaryMetric: raw.primaryMetric.flatMap(ChartsPrimaryMetric.init(rawValue:)) ?? .cost,
            accentOverrides: raw.accentOverrides ?? [:]
        )
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
