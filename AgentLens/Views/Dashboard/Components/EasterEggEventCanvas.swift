import OpenBurnBarCore
import SwiftUI

// MARK: - Event canvas
//
// Mounted by ``EasterEggOverlay`` only while an event is in flight. Owns a
// `TimelineView(.animation)` + `Canvas` that *steps* and draws the stateful
// ``EasterEggSimulation`` each frame (mirroring the website's `loop(now, dt)`),
// then calls `onFinished` once the simulation goes idle so the overlay can tear
// the whole tree down and return to zero cost.
//
// The provider/crest logos are resolved as Canvas *symbols* (the same
// `context.resolveSymbol` idiom ``BracketSwarmBackground`` uses) so the bundled
// imagesets draw at full fidelity without per-frame image decoding; the coin and
// cloud bodies are drawn procedurally to match the website's gradients exactly.

struct EasterEggEventCanvas: View {
    let event: EasterEggEvent
    let size: CGSize
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let ledges: [EasterEggSimulation.Ledge]
    let onFinished: () -> Void

    /// The stateful particle field, built once when the canvas appears.
    @State private var simulation: EasterEggSimulation?
    /// Last frame's `now` (ms, `startedAt`-relative) so `dt` is a real delta.
    @State private var lastTickMS: Double = -1
    @State private var didFinish = false
    /// The ordered logo/crest names the simulation indexes into.
    private let logoNames = EasterEggAssets.stormLogoNames
    private let crestNames = EasterEggAssets.cloudCrestNames

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, canvasSize in
                guard let simulation else { return }
                step(simulation, now: timeline.date, size: canvasSize)
                simulation.draw(
                    into: context,
                    resolveLogo: { index in
                        guard logoNames.indices.contains(index) else { return nil }
                        return context.resolveSymbol(id: EasterEggSymbolID.logo(assetName: logoNames[index]))
                    },
                    resolveCrest: { index in
                        guard crestNames.indices.contains(index) else { return nil }
                        return context.resolveSymbol(id: EasterEggSymbolID.logo(assetName: crestNames[index]))
                    }
                )
            } symbols: {
                symbolDeck
            }
        }
        .onAppear {
            if simulation == nil {
                let sim = EasterEggSimulation(kind: event.kind, reduceMotion: reduceMotion)
                // `begin` works in ms relative to the event's `startedAt`, the same
                // clock the canvas steps with, so every phase offset lines up.
                sim.begin(now: 0, size: size, ledges: ledges)
                simulation = sim
            }
            scheduleFinish()
        }
    }

    /// Advance the simulation using a real, clamped `dt` (matching the website's
    /// `Math.min(0.05, (now-last)/1000)`; first frame uses 0.016). Under Reduce
    /// Motion the timeline is paused and `begin` already no-op'd, so this never
    /// produces motion. `now` is `startedAt`-relative milliseconds.
    private func step(_ simulation: EasterEggSimulation, now date: Date, size: CGSize) {
        let nowMS = max(0, date.timeIntervalSince(event.startedAt) * 1000)
        let dt = lastTickMS >= 0 ? min(0.05, (nowMS - lastTickMS) / 1000) : 0.016
        lastTickMS = nowMS
        simulation.updateSize(size)
        simulation.step(now: nowMS, dt: max(0, dt))
    }

    /// Tear-down is time-based so it survives Reduce Motion (where the timeline is
    /// paused and the Canvas would otherwise never advance). The duration covers
    /// the full 5s takeover plus the rain/boundary tails.
    private func scheduleFinish() {
        guard !didFinish else { return }
        didFinish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + event.duration) {
            onFinished()
        }
    }

    // MARK: Symbol deck

    /// Every logo/crest the event might draw, tagged by a stable key. Resolving
    /// these once per frame (instead of re-rasterising images) keeps the Canvas
    /// cheap. Coins + clouds are procedural, so they need no symbols.
    @ViewBuilder
    private var symbolDeck: some View {
        ForEach(EasterEggSymbolID.allCases(for: event), id: \.self) { symbolID in
            symbolView(for: symbolID)
                .tag(symbolID)
        }
    }

    @ViewBuilder
    private func symbolView(for id: EasterEggSymbolID) -> some View {
        switch id {
        case .logo(let assetName):
            EasterEggLogoSymbol(assetName: assetName)
        }
    }
}

// MARK: - Symbol identifiers

/// Stable, hashable key for a Canvas symbol. Only the provider/crest logos are
/// symbols now; coins and clouds are drawn procedurally by the simulation.
enum EasterEggSymbolID: Hashable {
    case logo(assetName: String)

    /// The marks this event will ever draw, so the symbol deck stays small.
    static func allCases(for event: EasterEggEvent) -> [EasterEggSymbolID] {
        switch event.kind {
        case .logoStorm:
            return EasterEggAssets.stormLogoNames.map { .logo(assetName: $0) }
        case .cloudTokenRain:
            return EasterEggAssets.cloudCrestNames.map { .logo(assetName: $0) }
        case .boundary:
            return []
        }
    }
}

// MARK: - Symbol views

/// A single bundled logo/crest, loaded the same way ``UnifiedProviderLogoView``
/// loads it. Falls back to the BurnBar app crest if a name ever fails to
/// resolve, so the Canvas never draws an empty slot.
private struct EasterEggLogoSymbol: View {
    let assetName: String

    var body: some View {
        Group {
            if EasterEggAssets.imageExists(assetName) {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if EasterEggAssets.imageExists(EasterEggAssets.appCrestName) {
                Image(EasterEggAssets.appCrestName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "flame.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
        }
        .frame(width: 64, height: 64)
    }
}

// MARK: - Asset registry
//
// All names here are existing imagesets in AgentLens/Resources/Assets.xcassets,
// resolved the same way the constellation/swarm engine resolves them. Nothing
// is invented.

enum EasterEggAssets {
    /// BurnBar app crest — the universal fallback + a storm headliner.
    static let appCrestName = "AppLogo"

    /// Cloud-tier crests worn by the rain clouds (base / Pro / Ultra).
    static let cloudCrestNames = ["CloudTierCrest", "CloudTierCrestPro", "CloudTierCrestUltra"]

    /// The marks that burst in the dark-appearance logo storm: the BurnBar
    /// crests plus the provider logos already in the swarm-glyph showcase set
    /// (so the storm reuses precisely the constellation background's logo pool).
    static let stormLogoNames: [String] = {
        var names: [String] = [appCrestName] + cloudCrestNames
        for provider in AgentProvider.swarmGlyphProviders {
            let name = provider.bundledLogoName
            if imageExists(name), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }()

    /// Whether a named imageset resolves on this platform — mirrors
    /// ``UnifiedProviderLogoView``'s `NSImage(named:)` availability probe.
    static func imageExists(_ name: String) -> Bool {
        #if canImport(AppKit)
        return NSImage(named: NSImage.Name(name)) != nil
        #else
        return false
        #endif
    }
}
