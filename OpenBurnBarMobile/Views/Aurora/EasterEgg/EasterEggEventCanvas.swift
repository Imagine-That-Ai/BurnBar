import OpenBurnBarCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Event canvas

/// Mounted only while an easter egg event is active. The particle field is
/// deterministic per event, so each timeline tick is a pure draw of elapsed
/// time rather than mutable per-frame simulation.
struct EasterEggEventCanvas: View {
    let event: EasterEggEvent
    let size: CGSize
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let onFinished: () -> Void

    @State private var particleSystem: EasterEggParticleSystem?
    @State private var didScheduleFinish = false

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, canvasSize in
                guard let particleSystem else { return }
                particleSystem.draw(
                    into: context,
                    size: canvasSize,
                    elapsed: elapsedTime(now: timeline.date),
                    reduceMotion: reduceMotion
                )
            } symbols: {
                symbolDeck
            }
        }
        .onAppear {
            if particleSystem == nil {
                particleSystem = EasterEggParticleSystem(
                    performance: EasterEggPerformance(
                        event: event,
                        colorScheme: colorScheme,
                        reduceMotion: reduceMotion
                    )
                )
            }
            scheduleFinish()
        }
    }

    private func elapsedTime(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(event.startedAt))
    }

    private func scheduleFinish() {
        guard !didScheduleFinish else { return }
        didScheduleFinish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + event.duration) {
            onFinished()
        }
    }

    @ViewBuilder
    private var symbolDeck: some View {
        if let particleSystem {
            ForEach(particleSystem.imageTokens) { token in
                EasterEggLogoSymbol(assetName: token.assetName)
                    .tag(token.id)
            }
        }
    }
}

// MARK: - Performance model

struct EasterEggPerformance {
    enum Kind {
        case logoStorm
        case cloudTokenRain
        case boundaryBounce(atTop: Bool)
    }

    let id: UUID
    let kind: Kind
    let duration: TimeInterval
    let reduceMotion: Bool

    init(event: EasterEggEvent, colorScheme: ColorScheme, reduceMotion: Bool) {
        self.id = event.id
        self.reduceMotion = reduceMotion
        self.duration = event.duration

        switch event.kind {
        case .logoStorm:
            self.kind = .logoStorm
        case .cloudTokenRain:
            self.kind = .cloudTokenRain
        case .boundary(let edge):
            self.kind = .boundaryBounce(atTop: edge == .top)
        }
    }
}

// MARK: - Symbols

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
                    .foregroundStyle(Color(red: 0.94, green: 0.32, blue: 0.18))
            }
        }
        .frame(width: 64, height: 64)
    }
}

private enum EasterEggAssets {
    static let appCrestName = "AppLogo"

    static func imageExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name) != nil
        #else
        return false
        #endif
    }
}
