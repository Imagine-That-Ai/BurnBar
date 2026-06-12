import SwiftUI

struct BracketSwarmBackground: View {
    private static let braceSizes: [CGFloat] = [12, 14, 16, 18, 20, 22]
    private static let animationCadence: TimeInterval = 1.0 / 12.0

    var moodBand: MoodBand = .onPace

    @State private var swarms: [DashboardBraceSwarm] = []
    @State private var lastSize: CGSize = .zero

    private var densityMultiplier: Double {
        switch moodBand {
        case .light: return 0.5
        case .onPace: return 1.0
        case .heavy: return 1.8
        case .baseline, .quiet: return 0.7
        }
    }

    private var speedMultiplier: Double {
        switch moodBand {
        case .light: return 0.6
        case .onPace: return 1.0
        case .heavy: return 1.5
        case .baseline, .quiet: return 0.8
        }
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: Self.animationCadence)) { timeline in
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
                    guard !swarms.isEmpty else { return }
                    let time = timeline.date.timeIntervalSinceReferenceDate * speedMultiplier

                    for swarm in swarms {
                        let orbitPhase = (time / swarm.orbitDuration + swarm.orbitPhase) * .pi * 2
                        let breathePhase = (time / swarm.breatheDuration + swarm.breathePhase) * .pi * 2

                        let orbitX = sin(orbitPhase) * swarm.radius * 0.06
                        let orbitY = cos(orbitPhase) * swarm.radius * 0.05
                        let scale = 0.985 + 0.025 * sin(breathePhase)

                        var swarmContext = context
                        swarmContext.translateBy(
                            x: swarm.center.x + orbitX - swarm.radius,
                            y: swarm.center.y + orbitY - swarm.radius
                        )
                        swarmContext.scaleBy(x: scale, y: scale)

                        for brace in swarm.braces {
                            let point = CGPoint(
                                x: swarm.radius + brace.x,
                                y: swarm.radius + brace.y
                            )
                            guard let symbol = context.resolveSymbol(id: brace.symbolKey) else { continue }

                            var primaryContext = swarmContext
                            primaryContext.opacity = brace.opacity
                            primaryContext.draw(symbol, at: point, anchor: .center)
                        }
                    }
                } symbols: {
                    // Reuse a small set of brace glyph variants instead of re-resolving text every frame.
                    ForEach(braceSymbolKeys, id: \.self) { symbolKey in
                        braceSymbolView(for: symbolKey)
                            .tag(symbolKey)
                    }
                }
            }
            .onAppear {
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: proxy.size)
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: newSize)
                }
            }
            .onChange(of: moodBand) { _, _ in
                let size = proxy.size
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: size, force: true)
                }
            }
        }
    }

    private var bracePalettes: [DashboardBracePalette] {
        [
            DashboardBracePalette(
                primary: DesignSystem.Colors.ember.opacity(0.58),
                glow: DesignSystem.Colors.ember.opacity(0.24)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.amber.opacity(0.54),
                glow: DesignSystem.Colors.amber.opacity(0.22)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.blaze.opacity(0.50),
                glow: DesignSystem.Colors.blaze.opacity(0.20)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.whimsy.opacity(0.48),
                glow: DesignSystem.Colors.whimsy.opacity(0.18)
            )
        ]
    }

    private var braceSymbolKeys: [DashboardBraceSymbolKey] {
        bracePalettes.indices.flatMap { paletteIndex in
            Self.braceSizes.flatMap { size in
                [
                    DashboardBraceSymbolKey(size: Int(size.rounded()), paletteIndex: paletteIndex, isOpen: true),
                    DashboardBraceSymbolKey(size: Int(size.rounded()), paletteIndex: paletteIndex, isOpen: false)
                ]
            }
        }
    }

    @ViewBuilder
    private func braceSymbolView(for key: DashboardBraceSymbolKey) -> some View {
        let palette = bracePalettes[key.paletteIndex % bracePalettes.count]

        Text(key.isOpen ? "{" : "}")
            .font(.system(size: CGFloat(key.size), weight: .ultraLight, design: .rounded))
            .foregroundStyle(palette.primary.opacity(0.92))
            .shadow(color: palette.glow, radius: 3, x: 0, y: 0)
    }

    private func regenerateSwarmsIfNeeded(size: CGSize, force: Bool = false) {
        guard size != .zero else { return }
        if !force,
           abs(size.width - lastSize.width) < 1,
           abs(size.height - lastSize.height) < 1,
           !swarms.isEmpty {
            return
        }

        lastSize = size
        swarms = buildSwarms(size: size)
    }

    private func buildSwarms(size: CGSize) -> [DashboardBraceSwarm] {
        let swarmCount = max(2, Int(3 * densityMultiplier))
        let bracesPerSwarm = max(8, Int(18 * densityMultiplier))
        let padding: CGFloat = 80
        let width = max(size.width, padding * 2 + 1)
        let height = max(size.height, padding * 2 + 1)

        var result: [DashboardBraceSwarm] = []
        result.reserveCapacity(swarmCount)

        for _ in 0..<swarmCount {
            let radius = CGFloat.random(in: 90...190)
            let center = CGPoint(
                x: padding + CGFloat.random(in: 0...(width - padding * 2)),
                y: padding + CGFloat.random(in: 0...(height - padding * 2))
            )

            var braces: [DashboardBraceSpec] = []
            braces.reserveCapacity(bracesPerSwarm)

            for _ in 0..<bracesPerSwarm {
                let normalized = clampedGaussian()
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let distance = radius * abs(normalized)
                let x = cos(angle) * distance
                let y = sin(angle) * distance * CGFloat.random(in: 0.8...1.2)
                let symbolSize = Self.braceSizes.randomElement() ?? 16
                let paletteIndex = Int.random(in: 0..<bracePalettes.count)

                braces.append(
                    DashboardBraceSpec(
                        x: x,
                        y: y,
                        symbolKey: DashboardBraceSymbolKey(
                            size: Int(symbolSize.rounded()),
                            paletteIndex: paletteIndex,
                            isOpen: Bool.random()
                        ),
                        opacity: Double.random(in: 0.14...0.32)
                    )
                )
            }

            result.append(
                DashboardBraceSwarm(
                    center: center,
                    radius: radius,
                    braces: braces,
                    orbitPhase: Double.random(in: 0...1),
                    orbitDuration: Double.random(in: 70...130),
                    breathePhase: Double.random(in: 0...1),
                    breatheDuration: Double.random(in: 10...18)
                )
            )
        }

        return result
    }

    private func clampedGaussian() -> CGFloat {
        var u: Double = 0
        var v: Double = 0
        while u == 0 { u = Double.random(in: 0...1) }
        while v == 0 { v = Double.random(in: 0...1) }
        return max(-1.15, min(1.15, CGFloat(sqrt(-2.0 * log(u)) * cos(2.0 * .pi * v)) / 3))
    }
}

private struct DashboardBracePalette {
    let primary: Color
    let glow: Color
}

private struct DashboardBraceSpec: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let symbolKey: DashboardBraceSymbolKey
    let opacity: Double
}

private struct DashboardBraceSymbolKey: Hashable {
    let size: Int
    let paletteIndex: Int
    let isOpen: Bool
}

private struct DashboardBraceSwarm: Identifiable {
    let id = UUID()
    let center: CGPoint
    let radius: CGFloat
    let braces: [DashboardBraceSpec]
    let orbitPhase: Double
    let orbitDuration: Double
    let breathePhase: Double
    let breatheDuration: Double
}
