import SwiftUI
import OpenBurnBarCore

// MARK: - Easter Egg Overlay
//
// A single full-bleed, hit-test-DISABLED overlay mounted above the content at
// the app root. It idles at literally zero cost — no `TimelineView`, no
// timers, no particles — until `EasterEggScrollMonitor` publishes an event,
// at which point it spins up a `TimelineView(.animation)` + `Canvas` particle
// system for the duration of one performance, then tears the whole thing down
// (back to the idle `Color.clear`) so nothing keeps ticking.
//
// Theme is the system/app color scheme (`@Environment(\.colorScheme)`):
//   • dark  → "Logo Storm"  — BurnBar crests + provider logos pop in, drift
//             outward, twinkle, and fade across a few elegant bursts (~4.5s).
//   • light → "Cloud Token Rain" — soft grey clouds wearing cloud-tier crests
//             drift across the top and rain gold/silver token coins that fall
//             under gravity and BOUNCE off the screen edges (~5.5s).
// Boundary over-pulls play the cute "you've reached the end" token bounce at
// the pulled edge (~0.8s), regardless of theme.
//
// Reduced Motion is honored: the celebrations collapse to a single calm,
// static frame (one gentle fade) and the edge bounce becomes a quiet pop.
//
// Assets are reused verbatim from the swarm engine's provider set
// (`AgentProvider.swarmGlyphProviders` → `bundledLogoName`) and the cloud-tier
// crest assets already in `Assets.xcassets` (`CloudTierCrest*`). Token coins
// are drawn procedurally so they stay crisp gold/silver at any size.

struct EasterEggOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var monitor = EasterEggScrollMonitor.shared

    /// The performance currently playing, or `nil` while idle. Holding this in
    /// state — rather than reading the monitor directly — lets the overlay tear
    /// the `TimelineView` down the instant a show finishes.
    @State private var performance: EasterEggPerformance?
    /// Tracks which monitor event we've already consumed so an identical repeat
    /// (same payload) still starts a fresh show via the monotonic id.
    @State private var lastConsumedID: Int = 0

    var body: some View {
        Group {
            if let performance {
                EasterEggCanvas(
                    performance: performance,
                    reduceMotion: reduceMotion,
                    onFinished: { finished in
                        // Only clear if the show that finished is still the one
                        // on screen (a newer event may have replaced it).
                        if finished.id == performance.id {
                            self.performance = nil
                        }
                    }
                )
                .id(performance.id) // fresh TimelineView per show
                .transition(.opacity)
            } else {
                // Idle: a hit-test-disabled clear layer. No timeline, no
                // particles, no work — the overlay costs nothing until summoned.
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: monitor.eventID) { _, newID in
            guard newID != lastConsumedID, let event = monitor.event else { return }
            lastConsumedID = newID
            start(event)
        }
    }

    private func start(_ event: EasterEggEvent) {
        let kind: EasterEggPerformance.Kind
        switch event {
        case .summon:
            kind = colorScheme == .dark ? .logoStorm : .cloudTokenRain
        case .boundary(let atTop):
            kind = .boundaryBounce(atTop: atTop)
        }
        performance = EasterEggPerformance(kind: kind, reduceMotion: reduceMotion)
        // A soft, theme-appropriate confirmation tap.
        switch event {
        case .summon: HapticBus.milestone()
        case .boundary: HapticBus.chipChange()
        }
    }
}

// MARK: - Performance descriptor

/// One scheduled show: its kind, a frozen RNG seed (so the layout is stable
/// across the TimelineView's redraws), and the wall-clock instant it began.
struct EasterEggPerformance: Identifiable, Equatable {
    enum Kind: Equatable {
        case logoStorm
        case cloudTokenRain
        case boundaryBounce(atTop: Bool)
    }

    let id = UUID()
    let kind: Kind
    let reduceMotion: Bool
    let startedAt: Date = .now

    /// Total wall-clock length of the show. Reduced Motion shortens every
    /// celebration to a single calm fade.
    var duration: TimeInterval {
        if reduceMotion {
            switch kind {
            case .logoStorm, .cloudTokenRain: return 1.4
            case .boundaryBounce:             return 0.6
            }
        }
        switch kind {
        case .logoStorm:        return 4.6
        case .cloudTokenRain:   return 5.6
        case .boundaryBounce:   return 0.8
        }
    }
}

// MARK: - Canvas driver

/// Drives one performance: a `TimelineView(.animation)` ticks a `Canvas` that
/// advances and draws the particle field, then reports completion so the
/// parent can drop back to the idle `Color.clear`.
private struct EasterEggCanvas: View {
    let performance: EasterEggPerformance
    let reduceMotion: Bool
    let onFinished: (EasterEggPerformance) -> Void

    /// The live particle system. Rebuilt once per show keyed on `performance`.
    @State private var system: EasterEggParticleSystem
    @State private var hasFinished = false

    init(
        performance: EasterEggPerformance,
        reduceMotion: Bool,
        onFinished: @escaping (EasterEggPerformance) -> Void
    ) {
        self.performance = performance
        self.reduceMotion = reduceMotion
        self.onFinished = onFinished
        _system = State(initialValue: EasterEggParticleSystem(performance: performance))
    }

    var body: some View {
        TimelineView(.animation(paused: hasFinished)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(performance.startedAt)
                system.draw(into: context, size: size, elapsed: elapsed, reduceMotion: reduceMotion)
            } symbols: {
                // Pre-resolved logo/crest images, tagged for `context.resolveSymbol`.
                ForEach(system.imageTokens) { token in
                    Image(token.assetName)
                        .resizable()
                        .scaledToFit()
                        .tag(token.id)
                }
            }
            .onChange(of: timeline.date) {
                let elapsed = timeline.date.timeIntervalSince(performance.startedAt)
                if !hasFinished, elapsed >= performance.duration {
                    hasFinished = true
                    onFinished(performance)
                }
            }
        }
        .drawingGroup(opaque: false)
    }
}
