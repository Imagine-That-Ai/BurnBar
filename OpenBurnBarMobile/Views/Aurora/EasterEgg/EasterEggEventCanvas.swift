import OpenBurnBarCore
import SwiftUI

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
        case .coin(let metal):
            TokenCoinSymbol(metal: metal)
        case .cloud:
            CloudPuffSymbol()
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

    /// The marks this event will ever draw, so the symbol deck stays small.
    static func allCases(for event: EasterEggEvent) -> [EasterEggSymbolID] {
        switch event.kind {
        case .logoStorm:
            return EasterEggAssets.stormLogoNames.map { .logo(assetName: $0) }
        case .cloudTokenRain:
            return [.cloud]
                + EasterEggAssets.cloudCrestNames.map { .logo(assetName: $0) }
                + [.coin(metal: .gold), .coin(metal: .silver)]
        case .boundary:
            return [.coin(metal: .gold), .coin(metal: .silver)]
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

/// A small minted token coin. Gold + silver variants rain in the cloud event
/// and pop at the scroll boundaries. Drawn procedurally so it stays crisp at
/// any size; the RGB stops match the macOS coin hex palette for parity.
private struct TokenCoinSymbol: View {
    let metal: TokenMetal

    private var faceGradient: RadialGradient {
        switch metal {
        case .gold:
            return RadialGradient(
                colors: [
                    Color(red: 1.00, green: 0.91, blue: 0.66),  // FFE9A8
                    Color(red: 0.96, green: 0.72, blue: 0.25),  // F4B740
                    Color(red: 0.78, green: 0.53, blue: 0.11)   // C8881C
                ],
                center: .init(x: 0.38, y: 0.34),
                startRadius: 1,
                endRadius: 22
            )
        case .silver:
            return RadialGradient(
                colors: [
                    Color(red: 0.98, green: 0.98, blue: 0.99),  // FAFBFC
                    Color(red: 0.79, green: 0.82, blue: 0.85),  // C9D0D8
                    Color(red: 0.54, green: 0.58, blue: 0.63)   // 8A95A1
                ],
                center: .init(x: 0.38, y: 0.34),
                startRadius: 1,
                endRadius: 22
            )
        }
    }

    private var rimColor: Color {
        switch metal {
        case .gold: return Color(red: 0.61, green: 0.42, blue: 0.07)   // 9C6A12
        case .silver: return Color(red: 0.42, green: 0.45, blue: 0.50) // 6B747F
        }
    }

    private var glyphColor: Color {
        switch metal {
        case .gold: return Color(red: 0.61, green: 0.42, blue: 0.07).opacity(0.85)
        case .silver: return Color(red: 0.36, green: 0.40, blue: 0.44).opacity(0.85)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(faceGradient)
            Circle().strokeBorder(rimColor.opacity(0.8), lineWidth: 2)
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                .padding(3)
            // A token "$" mark so the coins read as spend, matching the brand's
            // dollar-formation swarm vocabulary.
            Text("$")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(glyphColor)
        }
        .frame(width: 30, height: 30)
        .shadow(color: rimColor.opacity(0.35), radius: 1.5, y: 0.5)
    }
}

/// A soft grey cloud puff that drifts across the top and rains coins.
private struct CloudPuffSymbol: View {
    var body: some View {
        ZStack {
            // Layered ellipses give a billowed silhouette without an asset.
            Capsule()
                .fill(.white.opacity(0.92))
                .frame(width: 120, height: 46)
                .offset(y: 10)
            Circle().fill(.white.opacity(0.95)).frame(width: 56, height: 56).offset(x: -28, y: -2)
            Circle().fill(.white.opacity(0.97)).frame(width: 72, height: 72).offset(x: 4, y: -10)
            Circle().fill(.white.opacity(0.94)).frame(width: 50, height: 50).offset(x: 38, y: 0)
        }
        .frame(width: 140, height: 84)
        .compositingGroup()
        .shadow(color: Color(red: 0.49, green: 0.53, blue: 0.58).opacity(0.35), radius: 6, y: 4)
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
