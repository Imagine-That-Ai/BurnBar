import Foundation
import SwiftUI

// MARK: - Swarm Color Driver
//
// A lightweight data structure that tells the swarm what colors to paint
// and how much weight each provider gets. Bridges real-time usage data
// into the particle color pipeline.
//
// When a provider is actively working, its brand color bleeds into the
// swarm field. When idle, the palette shifts to a weighted portrait of
// the day's usage footprint — the color of the air tells you who's burning.

public struct SwarmColorDriver: Equatable, Sendable {

    // MARK: - Types

    public enum Mode: String, Sendable {
        /// Providers are currently working — particle colors reflect live activity.
        case active
        /// No active session — particle colors reflect historical usage patterns.
        case idle
    }

    /// A single provider's share of the swarm's color palette.
    public struct ProviderWeight: Equatable, Sendable {
        /// Which provider this weight represents.
        public let provider: AgentProvider
        /// Normalized share of the palette (0…1). All weights should sum to ~1.
        public let weight: Double
        /// How close to exhaustion this provider is (0 = healthy, 1 = exhausted).
        /// Drives desaturation and red tinting of particles in this band.
        public let quotaPressure: Double

        public init(provider: AgentProvider, weight: Double, quotaPressure: Double = 0) {
            self.provider = provider
            self.weight = weight.clamped(to: 0...1)
            self.quotaPressure = quotaPressure.clamped(to: 0...1)
        }
    }

    // MARK: - Properties

    /// Whether providers are actively working or the system is idle.
    public let mode: Mode
    /// Provider color bands, sorted by weight descending. Weights should sum to ~1.
    public let providers: [ProviderWeight]
    /// Today's total cost in USD — drives overall intensity/brightness of the swarm.
    public let totalBurnRateUSD: Double

    /// All active providers who currently have non-zero usage weight.
    public var activeProviders: [AgentProvider] {
        guard mode == .active else { return [] }
        return providers.filter { $0.weight > 0 }.map { $0.provider }
    }

    // MARK: - Init

    public init(
        mode: Mode = .idle,
        providers: [ProviderWeight] = [],
        totalBurnRateUSD: Double = 0
    ) {
        self.mode = mode
        self.providers = providers
        self.totalBurnRateUSD = max(0, totalBurnRateUSD)
    }

    // MARK: - Color Resolution

    /// Resolves the RGBA color for a particle given its stable `colorIndex` (0…1).
    ///
    /// Maps the particle's index into the weighted provider bands. If the driver
    /// has no providers, returns `nil` and the caller should fall back to the
    /// default ember/amber/blaze palette.
    ///
    /// - Parameter colorIndex: The particle's stable random value in `[0, 1)`.
    /// - Returns: An RGBA tuple, or `nil` for fallback.
    public func resolveColor(for colorIndex: Double) -> RGBA? {
        guard let selection = providerSelection(for: colorIndex) else { return nil }
        let base = DesignSystemColors.providerRGBA(for: selection.provider)
        return pressureModulate(base: base, pressure: selection.quotaPressure)
    }

    /// Resolves a provider-family tonal shade for BurnBar logo flame particles.
    ///
    /// The normal `resolveColor(for:)` API intentionally stays exact-brand-color
    /// so non-flame particles remain clean provider indicators.
    public func resolveFlameTone(for colorIndex: Double, toneSeed: Double, role: String) -> RGBA? {
        guard let selection = providerSelection(for: colorIndex) else { return nil }
        let base = pressureModulate(
            base: DesignSystemColors.providerRGBA(for: selection.provider),
            pressure: selection.quotaPressure
        )
        return flameTone(base: base, provider: selection.provider, toneSeed: toneSeed, role: role)
    }

    /// Overall intensity multiplier derived from burn rate.
    /// $0/day → 0.6 (dim ambient), $5+/day → 1.0 (full brightness).
    public var intensityMultiplier: Double {
        let t = min(totalBurnRateUSD / 5.0, 1.0)
        return 0.6 + 0.4 * t
    }

    // MARK: - Private

    private func providerSelection(for colorIndex: Double) -> ProviderWeight? {
        guard !providers.isEmpty else { return nil }

        let index = min(max(colorIndex, 0), 0.999_999)
        var accumulated = 0.0
        for provider in providers {
            accumulated += provider.weight
            if index < accumulated {
                return provider
            }
        }
        return providers.last
    }

    /// Modulates a provider's base color toward desaturated red based on quota pressure.
    private func pressureModulate(base: RGBA, pressure: Double) -> RGBA {
        // At pressure=0: full brand color. At pressure=1: shift toward warning red.
        let warningR = 0.95
        let warningG = 0.15
        let warningB = 0.10
        let t = pressure * 0.6  // Cap the shift at 60% to keep color recognizable
        return RGBA(
            r: base.r * (1 - t) + warningR * t,
            g: base.g * (1 - t) + warningG * t,
            b: base.b * (1 - t) + warningB * t,
            a: base.a
        )
    }

    private func flameTone(base: RGBA, provider: AgentProvider, toneSeed: Double, role: String) -> RGBA {
        let seed = toneSeed - floor(toneSeed)
        let accent = flameAccent(for: provider, base: base)
        let hot = accent.lightened(by: 0.24)
        let shadow = base.darkened(by: role == "logo-flame-outer" ? 0.34 : 0.18)
        let lift = base.lightened(by: 0.20)
        let palette = [shadow, base, accent, hot, lift]
        let scaled = seed * Double(palette.count)
        let index = min(palette.count - 1, Int(scaled))
        let local = scaled - floor(scaled)
        let shade = palette[index].mix(with: palette[(index + 1) % palette.count], amount: local * 0.65)

        let amount: Double
        switch role {
        case "logo-flame-inner":
            amount = 0.62
        case "logo-flame-spark":
            amount = 0.76
        default:
            amount = 0.48
        }
        return base.mix(with: shade, amount: amount)
    }

    private func flameAccent(for provider: AgentProvider, base: RGBA) -> RGBA {
        switch provider {
        case .claudeCode:
            return RGBA(r: 1.00, g: 0.58, b: 0.40, a: base.a)
        case .codex, .openAI:
            return RGBA(r: 0.20, g: 1.00, b: 0.82, a: base.a)
        case .factory, .zai, .hermes, .piAgent:
            return RGBA(r: 0.72, g: 0.52, b: 1.00, a: base.a)
        case .cursor, .warp, .xAI:
            return RGBA(r: 0.86, g: 0.90, b: 0.96, a: base.a)
        case .openCode, .geminiCLI, .antigravity, .windsurf, .deepSeek, .kimi:
            return RGBA(r: 0.36, g: 0.66, b: 1.00, a: base.a)
        case .minimax:
            return RGBA(r: 1.00, g: 0.78, b: 0.22, a: base.a)
        case .openClaw, .rooCode:
            return RGBA(r: 1.00, g: 0.42, b: 0.52, a: base.a)
        case .forgeDev, .aider:
            return RGBA(r: 1.00, g: 0.50, b: 0.24, a: base.a)
        case .copilot, .kiloCode, .goose:
            return RGBA(r: 0.34, g: 1.00, b: 0.54, a: base.a)
        case .cline:
            return RGBA(r: 0.92, g: 0.68, b: 0.44, a: base.a)
        case .augment:
            return RGBA(r: 0.38, g: 0.60, b: 1.00, a: base.a)
        case .ollama:
            return RGBA(r: 0.64, g: 0.68, b: 0.72, a: base.a)
        }
    }
}

// MARK: - RGBA (lightweight, Canvas-friendly)

/// Raw RGBA components for use in Canvas drawing contexts where SwiftUI `Color`
/// cannot be used directly. Components are in `[0, 1]`.
public struct RGBA: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var color: Color {
        Color(red: r, green: g, blue: b).opacity(a)
    }
}

// MARK: - Clamped helper

extension RGBA {
    func mix(with other: RGBA, amount: Double) -> RGBA {
        let t = amount.clamped(to: 0...1)
        return RGBA(
            r: (r * (1 - t) + other.r * t).clamped(to: 0...1),
            g: (g * (1 - t) + other.g * t).clamped(to: 0...1),
            b: (b * (1 - t) + other.b * t).clamped(to: 0...1),
            a: (a * (1 - t) + other.a * t).clamped(to: 0...1)
        )
    }

    func lightened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 1, g: 1, b: 1, a: a), amount: amount)
    }

    func darkened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 0, g: 0, b: 0, a: a), amount: amount)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
