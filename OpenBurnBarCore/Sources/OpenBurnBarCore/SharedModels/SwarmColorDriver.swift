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
        guard !providers.isEmpty else { return nil }

        var accumulated = 0.0
        for pw in providers {
            accumulated += pw.weight
            if colorIndex < accumulated {
                let base = DesignSystemColors.providerRGBA(for: pw.provider)
                return pressureModulate(base: base, pressure: pw.quotaPressure)
            }
        }
        // Rounding residual — assign to last provider.
        if let last = providers.last {
            let base = DesignSystemColors.providerRGBA(for: last.provider)
            return pressureModulate(base: base, pressure: last.quotaPressure)
        }
        return nil
    }

    /// Overall intensity multiplier derived from burn rate.
    /// $0/day → 0.6 (dim ambient), $5+/day → 1.0 (full brightness).
    public var intensityMultiplier: Double {
        let t = min(totalBurnRateUSD / 5.0, 1.0)
        return 0.6 + 0.4 * t
    }

    // MARK: - Private

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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
