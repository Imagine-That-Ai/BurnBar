import SwiftUI
import OpenBurnBarKernel

public struct HolographicCrestAura: View {
    public enum Intensity: Sendable {
        case card
        case hero

        var opacity: Double {
            switch self {
            case .card: return 0.14
            case .hero: return 0.42
            }
        }

        var glowRadius: CGFloat {
            switch self {
            case .card: return 0
            case .hero: return 26
            }
        }
    }

    private let crestImageName: String
    private let gradient: LinearGradient
    private let intensity: Intensity

    public init(
        crestImageName: String,
        gradient: LinearGradient,
        intensity: Intensity = .card
    ) {
        self.crestImageName = crestImageName
        self.gradient = gradient
        self.intensity = intensity
    }

    public var body: some View {
        GeometryReader { geometry in
            let crest = gradient
                .mask(
                    Image(crestImageName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: geometry.size.width * 1.32, height: geometry.size.height * 1.32)
                        .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.42)
                )
                .saturation(1.2)
            ZStack {
                if intensity == .hero {
                    crest
                        .blur(radius: intensity.glowRadius)
                        .opacity(intensity.opacity * 0.8)
                }
                crest
                    .blur(radius: 0.5)
                    .opacity(intensity.opacity)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

public struct HoloSheenSweep: View {
    private let tint: Color
    private let period: Double
    private let bandOpacity: Double

    @State private var phase: CGFloat = -1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = .white, period: Double = 5.2, bandOpacity: Double = 0.30) {
        self.tint = tint
        self.period = period
        self.bandOpacity = bandOpacity
    }

    public var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.clear, tint.opacity(bandOpacity), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.45, height: geometry.size.height * 1.8)
            .rotationEffect(.degrees(16))
            .offset(x: phase * geometry.size.width, y: -geometry.size.height * 0.4)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

public struct HoloSparksOverlay: View {
    private let colors: [Color]
    private let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(colors: [Color], count: Int = 10) {
        self.colors = colors
        self.count = count
    }

    public var body: some View {
        if reduceMotion || colors.isEmpty {
            Color.clear
                .allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                Canvas { ctx, size in
                    let t = context.date.timeIntervalSinceReferenceDate
                    for index in 0..<count {
                        let seed = Double(index) * 1.618
                        let phase = (t * 0.16 + seed).truncatingRemainder(dividingBy: 1.0)
                        let drift = sin((t * 0.5) + seed * 7.3) * 0.04
                        let x = size.width * (0.12 + ((sin(seed * 5.7) + 1) * 0.38) + drift)
                        let y = size.height * (0.92 - 0.74 * phase)
                        let radius = 1.0 + 0.8 * CGFloat((sin(seed * 9.1) + 1) / 2)
                        ctx.opacity = (1.0 - phase) * 0.55
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(colors[index % colors.count])
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

public extension CloudTier {
    var holoStops: [Color] {
        switch self {
        case .none, .cloud:
            return [Color(hex: "FFD56B"), Color(hex: "FF8A3D"), Color(hex: "FF5C8A"), Color(hex: "B06BFF")]
        case .pro:
            return [Color(hex: "5EF0C9"), Color(hex: "38D6F3"), Color(hex: "4F8BFF"), Color(hex: "8EF0A8")]
        case .ultra:
            return [Color(hex: "FFD56B"), Color(hex: "7DD3FC"), Color(hex: "C084FC"), Color(hex: "5EEAD4"), Color(hex: "FF9EC7")]
        }
    }

    var holoGradient: LinearGradient {
        LinearGradient(colors: holoStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var membershipName: String {
        switch self {
        case .none, .cloud: return "Cloud"
        case .pro: return "Cloud Pro"
        case .ultra: return "Cloud Ultra"
        }
    }
}

public struct HouseCrest: View {
    private let house: CastleHouse
    private let size: CGFloat
    private let primary: Color
    private let accent: Color
    private let phase: CastleWorkerPhase

    public init(
        house: CastleHouse,
        size: CGFloat = 56,
        primary: Color,
        accent: Color,
        phase: CastleWorkerPhase = .running
    ) {
        self.house = house
        self.size = size
        self.primary = primary
        self.accent = accent
        self.phase = phase
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primary.opacity(0.28), accent.opacity(0.10), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: size * 0.8
                    )
                )
            Circle()
                .strokeBorder(ringStyle, lineWidth: phase == .landed ? 1.6 : 1.0)
            if let crestAsset = house.crestAsset {
                HolographicCrestAura(
                    crestImageName: crestAsset,
                    gradient: LinearGradient(colors: [primary, accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                    intensity: phase == .landed ? .hero : .card
                )
                .clipShape(Circle())
                Image(crestAsset)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(size * 0.22)
            } else {
                Image(systemName: house.sigil)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(house.name)
    }

    private var ringStyle: AnyShapeStyle {
        switch phase {
        case .landed:
            return AnyShapeStyle(LinearGradient(colors: [primary, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .failed, .noOp:
            return AnyShapeStyle(primary.opacity(0.35))
        default:
            return AnyShapeStyle(primary.opacity(0.65))
        }
    }
}
