import OpenBurnBarCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Event canvas
//
// Mounted by ``EasterEggOverlay`` only while an event is in flight. Owns a
// `TimelineView(.animation)` + `Canvas` that simulates and draws the particles,
// then calls `onFinished` once the event's duration has elapsed so the overlay
// can tear the whole tree down and return to zero cost.
//
// All marks are resolved as Canvas *symbols* (the same `context.resolveSymbol`
// idiom ``SwarmCanvasView`` uses), so the bundled logo/crest imagesets draw at
// full fidelity without per-frame image decoding. This mirrors the macOS
// (`AgentLens`) easter egg canvas verbatim so every surface feels identical.

struct EasterEggEventCanvas: View {
    let event: EasterEggEvent
    let size: CGSize
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let onFinished: () -> Void

    /// Particle field, built once when the canvas appears (deterministic per
    /// event id) so the Canvas closure stays a pure function of elapsed time.
    @State private var scene: EasterEggScene?
    @State private var didFinish = false

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, canvasSize in
                guard let scene else { return }
                let elapsed = elapsedTime(now: timeline.date)
                scene.draw(into: context, size: canvasSize, elapsed: elapsed, reduceMotion: reduceMotion)
            } symbols: {
                symbolDeck
            }
        }
        .onAppear {
            if scene == nil {
                scene = EasterEggScene.make(for: event, size: size, colorScheme: colorScheme)
            }
            scheduleFinish()
        }
    }

    private func elapsedTime(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(event.startedAt))
    }

    /// Tear-down is time-based so it survives Reduce Motion (where the timeline
    /// is paused and the Canvas would otherwise never advance).
    private func scheduleFinish() {
        guard !didFinish else { return }
        didFinish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + event.duration) {
            onFinished()
        }
    }

    // MARK: Symbol deck

    /// Every mark the event might draw, tagged by a stable key. Resolving these
    /// once per frame (instead of re-rasterising images) keeps the Canvas cheap.
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
        case .coin, .cloud:
            // Coins + clouds are drawn procedurally by the scene now (edge-on
            // coin flip + fluffy puffPath clouds); they resolve no image symbol.
            EmptyView()
        }
    }
}

// MARK: - Symbol identifiers

/// Stable, hashable key for a Canvas symbol. Built from the bundled asset
/// catalog names already used by the constellation background.
enum EasterEggSymbolID: Hashable {
    case logo(assetName: String)
    case coin(metal: TokenMetal)
    case cloud

    /// The image marks this event resolves as Canvas symbols. Coins, clouds, and
    /// the cloud body are all drawn *procedurally* now (edge-on coin flip, fluffy
    /// puffPath clouds), so only the logo/crest PNGs need resolving here.
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

enum TokenMetal: Hashable {
    case gold
    case silver
}

// MARK: - Symbol views

/// A single bundled logo/crest, loaded the same way ``ProviderAvatar`` loads it.
/// Falls back to the BurnBar app crest if a name ever fails to resolve, so the
/// Canvas never draws an empty slot.
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
                    .foregroundStyle(MobileTheme.ember)
            }
        }
        .frame(width: 64, height: 64)
    }
}

// MARK: - Asset registry
//
// All names here are existing imagesets in
// OpenBurnBarMobile/Resources/Assets.xcassets, resolved the same way the
// constellation/swarm engine resolves them. Nothing is invented.

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
    /// ``ProviderAvatar``'s `UIImage(named:)` availability probe.
    static func imageExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name) != nil
        #else
        return false
        #endif
    }
}
