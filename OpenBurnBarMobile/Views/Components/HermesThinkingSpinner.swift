import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Thinking Style

/// User-selectable "Hermes is thinking" animation. One legacy mercury-droplet
/// style plus a full deck of braille spinners (the `unicode-animations` set).
/// Style, color, and size persist app-wide via `@AppStorage` and render
/// through `HermesThinkingSpinner`, so every thinking surface (Hermes chat,
/// Quick Ask, Agent Live Stage, Chart Studio) follows the same preference.
enum HermesThinkingStyle: String, CaseIterable, Identifiable {
    case swarm
    case braille
    case orbit
    case breathe
    case snake
    case fillsweep
    case diagswipe
    case scan
    case pulse
    case cascade
    case columns
    case scanline
    case checkerboard
    case rain
    case sparkle
    case waverows
    case helix
    case braillewave
    case dna
    case droplets

    static let storageKey = "hermesThinkingStyle"
    static let defaultStyle: HermesThinkingStyle = .swarm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .swarm:        return "Swarm"
        case .braille:      return "Braille"
        case .orbit:        return "Orbit"
        case .breathe:      return "Breathe"
        case .snake:        return "Snake"
        case .fillsweep:    return "Fill Sweep"
        case .diagswipe:    return "Diag Swipe"
        case .scan:         return "Scan"
        case .pulse:        return "Pulse"
        case .cascade:      return "Cascade"
        case .columns:      return "Columns"
        case .scanline:     return "Scanline"
        case .checkerboard: return "Checkerboard"
        case .rain:         return "Rain"
        case .sparkle:      return "Sparkle"
        case .waverows:     return "Wave Rows"
        case .helix:        return "Helix"
        case .braillewave:  return "Braille Wave"
        case .dna:          return "DNA"
        case .droplets:     return "Droplets"
        }
    }

    /// Seconds per frame. Tuned per style so dense multi-cell patterns read
    /// as motion instead of flicker.
    var frameInterval: TimeInterval {
        switch self {
        case .braille, .snake:                     return 0.08
        case .orbit, .braillewave:                 return 0.10
        case .breathe, .fillsweep, .diagswipe:     return 0.12
        case .scan, .pulse, .cascade, .columns:    return 0.14
        case .rain, .sparkle, .waverows, .dna:     return 0.16
        case .scanline, .helix:                    return 0.18
        case .checkerboard:                        return 0.30
        case .droplets:                            return 0.10 // unused — droplets animate natively
        case .swarm:                               return 0.10 // unused — swarm animates natively
        }
    }

    /// Braille frame deck. `U+2800` (blank braille cell) keeps multi-cell
    /// frames the same width so the glyph never jitters horizontally.
    var frames: [String] {
        switch self {
        case .braille:
            return ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        case .orbit:
            return ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
        case .breathe:
            return ["⠀", "⠂", "⠒", "⠖", "⠶", "⡶", "⣶", "⣾", "⣿", "⣾", "⣶", "⡶", "⠶", "⠖", "⠒", "⠂"]
        case .snake:
            return ["⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓"]
        case .fillsweep:
            return ["⡀", "⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿", "⢿", "⠿", "⠻", "⠛", "⠙", "⠉", "⠈", "⠀"]
        case .diagswipe:
            return ["⠁", "⠉", "⠋", "⠛", "⠟", "⠿", "⡿", "⣿", "⣾", "⣴", "⣠", "⣀", "⡀", "⠀"]
        case .scan:
            return ["⡇⠀⠀", "⢸⠀⠀", "⠀⡇⠀", "⠀⢸⠀", "⠀⠀⡇", "⠀⠀⢸", "⠀⠀⡇", "⠀⢸⠀", "⠀⡇⠀", "⢸⠀⠀"]
        case .pulse:
            return ["⢀⡀", "⢤⡤", "⢶⡶", "⣿⣿", "⢶⡶", "⢤⡤"]
        case .cascade:
            return ["⠀⠀⠀⢀", "⠀⠀⢀⡴", "⠀⢀⡴⠋", "⢀⡴⠋⠁", "⡴⠋⠁⠀", "⠋⠁⠀⠀", "⠁⠀⠀⠀", "⠀⠀⠀⠀"]
        case .columns:
            return ["⣿⡇⠀⠀", "⠀⣿⡇⠀", "⠀⠀⣿⡇", "⡇⠀⠀⣿"]
        case .scanline:
            return ["⠉⠉⠉", "⠒⠒⠒", "⠤⠤⠤", "⣀⣀⣀", "⠤⠤⠤", "⠒⠒⠒"]
        case .checkerboard:
            return ["⡪⡪⡪", "⢕⢕⢕"]
        case .rain:
            return ["⠂⠌⡠⠐", "⠐⠂⠌⡠", "⡠⠐⠂⠌", "⠌⡠⠐⠂"]
        case .sparkle:
            return ["⠊⡰⡡⡘", "⡘⠊⡰⡡", "⡡⡘⠊⡰", "⡰⡡⡘⠊"]
        case .waverows:
            return ["⠙⠢⣄⣠", "⣠⠙⠢⣄", "⣄⣠⠙⠢", "⠢⣄⣠⠙"]
        case .helix:
            return ["⣉⡱⣉⡱", "⡱⣉⡱⣉"]
        case .braillewave:
            return ["⠠⠐⠈⠁", "⠁⠠⠐⠈", "⠈⠁⠠⠐", "⠐⠈⠁⠠"]
        case .dna:
            return ["⠉⠙⠚⠒", "⠒⠉⠙⠚", "⠚⠒⠉⠙", "⠙⠚⠒⠉"]
        case .droplets:
            return ["⠿"] // placeholder — droplets render via MercuryThinkingIndicator
        case .swarm:
            return ["⠿"] // placeholder — swarm renders via SwarmDotsThinkingIndicator
        }
    }
}

// MARK: - Hermes Thinking Color

/// The spinner's color treatment. `provider` and `model` resolve live from
/// whatever is currently routing the conversation; `custom` reads the hex the
/// user picked with the system color picker.
enum HermesThinkingColorChoice: String, CaseIterable, Identifiable {
    case subtle
    case mono
    case provider
    case model
    case ember
    case amber
    case blaze
    case whimsy
    case aureate
    case mercury
    case rainbow
    case custom

    static let storageKey = "hermesThinkingColor"
    static let customHexKey = "hermesThinkingCustomColorHex"
    static let defaultChoice: HermesThinkingColorChoice = .subtle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle:   return "Subtle"
        case .mono:     return "Black & White"
        case .provider: return "Provider"
        case .model:    return "Model"
        case .ember:    return "Ember"
        case .amber:    return "Amber"
        case .blaze:    return "Blaze"
        case .whimsy:   return "Whimsy"
        case .aureate:  return "Aureate"
        case .mercury:  return "Mercury"
        case .rainbow:  return "Rainbow"
        case .custom:   return "Custom"
        }
    }

    /// Resolves the working shape style. `date` drives the rainbow cycle;
    /// `provider`/`modelName` feed the data-driven choices and fall back to
    /// Hermes aureate when the surface has no routing context.
    func shapeStyle(
        date: Date,
        provider: AgentProvider?,
        modelName: String?,
        customHex: String,
        reduceMotion: Bool
    ) -> AnyShapeStyle {
        switch self {
        case .subtle:
            return AnyShapeStyle(MobileTheme.Colors.textSecondary)
        case .mono:
            return AnyShapeStyle(MobileTheme.Colors.textPrimary)
        case .provider:
            guard let provider else { return AnyShapeStyle(MobileTheme.hermesAureate) }
            return AnyShapeStyle(MobileTheme.Colors.primary(for: provider))
        case .model:
            guard let modelName, !modelName.isEmpty else {
                return AnyShapeStyle(MobileTheme.hermesAureate)
            }
            return AnyShapeStyle(MobileTheme.Colors.colorForModel(modelName))
        case .ember:
            return AnyShapeStyle(MobileTheme.ember)
        case .amber:
            return AnyShapeStyle(MobileTheme.amber)
        case .blaze:
            return AnyShapeStyle(MobileTheme.blaze)
        case .whimsy:
            return AnyShapeStyle(MobileTheme.whimsy)
        case .aureate:
            return AnyShapeStyle(MobileTheme.hermesAureate)
        case .mercury:
            return AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
        case .rainbow:
            return AnyShapeStyle(Self.rainbowColor(at: date, frozen: reduceMotion))
        case .custom:
            return AnyShapeStyle(Color(hex: customHex))
        }
    }

    /// Full spectrum sweep, one lap every ~6 seconds.
    static func rainbowColor(at date: Date, frozen: Bool) -> Color {
        guard !frozen else { return MobileTheme.hermesAureate }
        let hue = (date.timeIntervalSinceReferenceDate / 6).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.78, brightness: 1.0)
    }
}

// MARK: - Hermes Thinking Size

enum HermesThinkingSizeChoice: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case huge

    static let storageKey = "hermesThinkingSize"
    static let defaultChoice: HermesThinkingSizeChoice = .medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .huge:   return "Huge"
        }
    }

    /// Point size for braille glyph styles.
    var pointSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 18
        case .large:  return 24
        case .huge:   return 32
        }
    }

    /// Scale factor applied to the mercury droplets style.
    var dropletScale: CGFloat {
        switch self {
        case .small:  return 0.8
        case .medium: return 1.0
        case .large:  return 1.35
        case .huge:   return 1.75
        }
    }
}

// MARK: - Hermes Thinking Spinner

/// The thinking indicator. Renders the user's chosen style/color/size
/// (or explicit overrides for previews/pickers).
///
/// Braille styles animate through `TimelineView(.periodic)` — pure
/// clock-driven frame swaps, no `repeatForever` state animations competing
/// with the swarm canvas for the frame budget.
struct HermesThinkingSpinner: View {
    /// Routing context for the `provider`/`model` color choices. Surfaces
    /// without a routed model pass `nil` and fall back to Hermes aureate.
    var provider: AgentProvider?
    var modelName: String?
    /// Pin a specific style/color/size (picker previews). `nil` follows the
    /// user preference.
    var styleOverride: HermesThinkingStyle?
    var colorOverride: HermesThinkingColorChoice?
    var sizeOverride: HermesThinkingSizeChoice?

    @AppStorage(HermesThinkingStyle.storageKey)
    private var selectedStyleRaw: String = HermesThinkingStyle.defaultStyle.rawValue
    @AppStorage(HermesThinkingColorChoice.storageKey)
    private var selectedColorRaw: String = HermesThinkingColorChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingSizeChoice.storageKey)
    private var selectedSizeRaw: String = HermesThinkingSizeChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingColorChoice.customHexKey)
    private var customColorHex: String = "FF9F0A"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        provider: AgentProvider? = nil,
        modelName: String? = nil,
        styleOverride: HermesThinkingStyle? = nil,
        colorOverride: HermesThinkingColorChoice? = nil,
        sizeOverride: HermesThinkingSizeChoice? = nil
    ) {
        self.provider = provider
        self.modelName = modelName
        self.styleOverride = styleOverride
        self.colorOverride = colorOverride
        self.sizeOverride = sizeOverride
    }

    private var style: HermesThinkingStyle {
        styleOverride ?? HermesThinkingStyle(rawValue: selectedStyleRaw) ?? .defaultStyle
    }

    private var colorChoice: HermesThinkingColorChoice {
        colorOverride ?? HermesThinkingColorChoice(rawValue: selectedColorRaw) ?? .defaultChoice
    }

    private var size: HermesThinkingSizeChoice {
        sizeOverride ?? HermesThinkingSizeChoice(rawValue: selectedSizeRaw) ?? .defaultChoice
    }

    var body: some View {
        Group {
            if style == .swarm {
                SwarmDotsThinkingIndicator(
                    glyphProvider: provider ?? .hermes,
                    scale: size.pointSize / HermesThinkingSizeChoice.medium.pointSize,
                    usesBrandGlyphColors: colorChoice == .subtle || colorChoice == .provider,
                    shading: { date in resolvedStyle(date: date) }
                )
                .padding(.vertical, MobileTheme.Spacing.xs)
                .padding(.horizontal, MobileTheme.Spacing.sm)
            } else if style == .droplets {
                dropletsBody
            } else if reduceMotion {
                frameText(style.frames[0], date: .now)
                    .padding(MobileTheme.Spacing.md)
            } else {
                TimelineView(.periodic(from: .now, by: style.frameInterval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / style.frameInterval)
                    let index = ((tick % style.frames.count) + style.frames.count) % style.frames.count
                    frameText(style.frames[index], date: context.date)
                }
                .padding(MobileTheme.Spacing.md)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes is thinking")
    }

    // MARK: Braille frames

    private func frameText(_ frame: String, date: Date) -> some View {
        Text(frame)
            .font(.system(size: size.pointSize, weight: .regular, design: .monospaced))
            .foregroundStyle(resolvedStyle(date: date))
            .fixedSize()
    }

    private func resolvedStyle(date: Date) -> AnyShapeStyle {
        colorChoice.shapeStyle(
            date: date,
            provider: provider,
            modelName: modelName,
            customHex: customColorHex,
            reduceMotion: reduceMotion
        )
    }

    // MARK: Droplets

    /// Droplets keep their native pooling animation; size scales the whole
    /// cluster and color tints the droplet gradient. Rainbow cycles via a
    /// low-rate hue rotation so the droplets path stays clock-driven too.
    @ViewBuilder
    private var dropletsBody: some View {
        let scaled = MercuryThinkingIndicator(tint: dropletTint)
            .scaleEffect(size.dropletScale)
            .frame(
                width: 60 * size.dropletScale,
                height: 34 * size.dropletScale
            )
        if colorChoice == .rainbow && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                scaled.hueRotation(.degrees(
                    (context.date.timeIntervalSinceReferenceDate * 60)
                        .truncatingRemainder(dividingBy: 360)
                ))
            }
        } else {
            scaled
        }
    }

    private var dropletTint: Color? {
        switch colorChoice {
        case .subtle, .mercury:
            return nil // native mercury gradient
        case .mono:
            return MobileTheme.Colors.textPrimary
        case .provider:
            return provider.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.hermesAureate
        case .model:
            guard let modelName, !modelName.isEmpty else { return MobileTheme.hermesAureate }
            return MobileTheme.Colors.colorForModel(modelName)
        case .ember:   return MobileTheme.ember
        case .amber:   return MobileTheme.amber
        case .blaze:   return MobileTheme.blaze
        case .whimsy:  return MobileTheme.whimsy
        case .aureate: return MobileTheme.hermesAureate
        case .rainbow: return MobileTheme.ember // base hue; hueRotation cycles it
        case .custom:  return Color(hex: customColorHex)
        }
    }
}

// MARK: - Swarm Dots Indicator

/// The default thinking indicator: a miniature of the backdrop murmuration.
/// A small particle swarm converges into the active provider's brand glyph
/// (in the logo's real sampled colors), holds, then dissolves and pools into
/// three reading dots — and back, forever. Same point clouds as the big swarm
/// (`SwarmGlyphSampler`), same "form by swarm" motion language.
private struct SwarmDotsThinkingIndicator: View {
    let glyphProvider: AgentProvider
    /// 1.0 at medium; scales the whole stage.
    let scale: CGFloat
    /// True for the "authentic" color treatments (Subtle/Provider): the glyph
    /// phase shows the logo's real sampled colors, crossfading to the user's
    /// shading as the particles pool into dots. Explicit color picks rule the
    /// whole cycle.
    let usesBrandGlyphColors: Bool
    /// Resolves the user's color choice at a moment in time (rainbow cycles).
    let shading: (Date) -> AnyShapeStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glyphPoints: [SwarmGlyphPoint] = []

    /// Full cycle length. Phases: glyph hold -> scatter to dots -> dots hold
    /// -> scatter back.
    private static let period: Double = 4.6
    private static let glyphHoldEnd: Double = 1.5
    private static let toDotsEnd: Double = 2.3
    private static let dotsHoldEnd: Double = 3.8

    private var stageSize: CGSize {
        CGSize(width: 76 * scale, height: 34 * scale)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { graphics, size in
                draw(in: &graphics, size: size, date: context.date)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .onAppear {
            glyphPoints = SwarmGlyphSampler.glyphPoints(for: glyphProvider, maxPoints: 84)
        }
        .onChange(of: glyphProvider) { _, newProvider in
            glyphPoints = SwarmGlyphSampler.glyphPoints(for: newProvider, maxPoints: 84)
        }
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, date: Date) {
        let points = glyphPoints.isEmpty ? Self.fallbackRing : glyphPoints
        let count = points.count
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let glyphRadius = min(size.width, size.height) * 0.46
        let dotSpread = size.width * 0.29
        let dotClusterRadius = 2.6 * scale
        let clusterCenters: [CGPoint] = [
            CGPoint(x: center.x - dotSpread, y: center.y),
            center,
            CGPoint(x: center.x + dotSpread, y: center.y)
        ]
        let t = date.timeIntervalSinceReferenceDate
        let phase = t.truncatingRemainder(dividingBy: Self.period)
        let perCluster = Double((count + 2) / 3)
        let userStyle = shading(date)

        for index in 0..<count {
            let hashA = Self.unitHash(index, salt: 1)
            let hashB = Self.unitHash(index, salt: 2)

            // Morph parameter: 0 = glyph formation, 1 = three dots.
            // Per-particle stagger makes departures ragged — swarm, not slide.
            let stagger = hashA * 0.35
            let m: Double
            if reduceMotion {
                m = 1
            } else if phase < Self.glyphHoldEnd {
                m = 0
            } else if phase < Self.toDotsEnd {
                m = Self.smoothstep((phase - Self.glyphHoldEnd - stagger) / (Self.toDotsEnd - Self.glyphHoldEnd - 0.35))
            } else if phase < Self.dotsHoldEnd {
                m = 1
            } else {
                m = 1 - Self.smoothstep((phase - Self.dotsHoldEnd - stagger) / (Self.period - Self.dotsHoldEnd - 0.35))
            }

            let glyphPoint = points[index % count]
            let glyphTarget = CGPoint(
                x: center.x + glyphPoint.position.x * glyphRadius,
                y: center.y + glyphPoint.position.y * glyphRadius
            )

            let cluster = index % 3
            let u = (Double(index / 3) + 0.5) / perCluster
            let spiralRadius = dotClusterRadius * sqrt(u)
            let spiralAngle = Double(index) * 2.39996323
            let dotTarget = CGPoint(
                x: clusterCenters[cluster].x + cos(spiralAngle) * spiralRadius,
                y: clusterCenters[cluster].y + sin(spiralAngle) * spiralRadius
            )

            // Wobble is gentle while held in formation and chaotic mid-flight.
            let chaos = reduceMotion ? 0 : (0.5 + 9.0 * m * (1 - m)) * scale
            let wobbleX = sin(t * (1.3 + hashA * 1.4) + hashB * .pi * 2) * chaos
            let wobbleY = cos(t * (1.1 + hashB * 1.6) + hashA * .pi * 2) * chaos

            let position = CGPoint(
                x: glyphTarget.x + (dotTarget.x - glyphTarget.x) * m + wobbleX,
                y: glyphTarget.y + (dotTarget.y - glyphTarget.y) * m + wobbleY
            )

            // Particles read denser in the glyph, plumper as pooled dots.
            let radius = (0.9 + 0.5 * hashB + 0.9 * m) * scale
            let rect = CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let path = Path(ellipseIn: rect)
            let baseOpacity = 0.62 + 0.38 * hashA

            // Brand-true glyph: logo colors while formed, crossfading to the
            // user's shading as particles pool into dots. Two weighted fills
            // only during the brief transition window.
            if usesBrandGlyphColors, let brand = glyphPoint.brandColor {
                if m < 1 {
                    graphics.opacity = baseOpacity * (1 - m) * brand.a
                    graphics.fill(path, with: .color(brand.color))
                }
                if m > 0 {
                    graphics.opacity = baseOpacity * m
                    graphics.fill(path, with: .style(userStyle))
                }
            } else {
                graphics.opacity = baseOpacity
                graphics.fill(path, with: .style(userStyle))
            }
        }
    }

    /// Deterministic per-particle randomness — no `random()` so frames are
    /// pure functions of (index, time).
    private static func unitHash(_ index: Int, salt: Int) -> Double {
        var value = UInt64(bitPattern: Int64(index &+ salt &* 7919)) &* 2654435761
        value ^= value >> 13
        value = value &* 1099511628211
        return Double(value % 4096) / 4096.0
    }

    private static func smoothstep(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Last-resort formation while glyph sampling warms (or has no logo):
    /// a clean ring, so the indicator never renders as scattered noise.
    private static let fallbackRing: [SwarmGlyphPoint] = (0..<84).map { index in
        let angle = Double(index) / 84.0 * .pi * 2
        return SwarmGlyphPoint(
            position: CGPoint(x: cos(angle), y: sin(angle)),
            brandColor: nil
        )
    }
}

// MARK: - Thinking Style Picker Sheet

/// "Tons of choices" — live previews for every style, color treatment, and
/// size. Everything applies instantly and persists app-wide.
struct HermesThinkingStylePickerSheet: View {
    /// Routing context so the Provider/Model swatches preview the real colors.
    var provider: AgentProvider?
    var modelName: String?

    @AppStorage(HermesThinkingStyle.storageKey)
    private var selectedStyleRaw: String = HermesThinkingStyle.defaultStyle.rawValue
    @AppStorage(HermesThinkingColorChoice.storageKey)
    private var selectedColorRaw: String = HermesThinkingColorChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingSizeChoice.storageKey)
    private var selectedSizeRaw: String = HermesThinkingSizeChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingColorChoice.customHexKey)
    private var customColorHex: String = "FF9F0A"
    @State private var customPickerColor: Color = Color(hex: "FF9F0A")
    @Environment(\.dismiss) private var dismiss

    init(provider: AgentProvider? = nil, modelName: String? = nil) {
        self.provider = provider
        self.modelName = modelName
    }

    private let styleColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    private let colorColumns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    previewCard
                    section("Style") {
                        LazyVGrid(columns: styleColumns, spacing: 10) {
                            ForEach(HermesThinkingStyle.allCases) { style in
                                styleCell(style)
                            }
                        }
                    }
                    section("Color") {
                        LazyVGrid(columns: colorColumns, spacing: 10) {
                            ForEach(HermesThinkingColorChoice.allCases) { choice in
                                colorCell(choice)
                            }
                        }
                    }
                    section("Size") {
                        HStack(spacing: 10) {
                            ForEach(HermesThinkingSizeChoice.allCases) { choice in
                                sizeCell(choice)
                            }
                        }
                    }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(MobileTheme.Colors.background)
            .navigationTitle("Thinking Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large, .medium])
        .onAppear { customPickerColor = Color(hex: customColorHex) }
    }

    // MARK: Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MobileTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            content()
        }
    }

    /// Hero: the exact spinner the app will show, live.
    private var previewCard: some View {
        HStack {
            Spacer()
            HermesThinkingSpinner(provider: provider, modelName: modelName)
            Spacer()
        }
        .frame(minHeight: 84)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: Style cells

    private func styleCell(_ style: HermesThinkingStyle) -> some View {
        let isSelected = selectedStyleRaw == style.rawValue
        return Button {
            selectedStyleRaw = style.rawValue
            Haptics.light()
        } label: {
            VStack(spacing: 4) {
                HermesThinkingSpinner(
                    provider: provider,
                    modelName: modelName,
                    styleOverride: style,
                    sizeOverride: .medium
                )
                .frame(height: 44)
                Text(style.displayName)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selectionFill(isSelected, cornerRadius: 14))
            .overlay(selectionStroke(isSelected, cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.displayName) thinking style")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Color cells

    private func colorCell(_ choice: HermesThinkingColorChoice) -> some View {
        let isSelected = selectedColorRaw == choice.rawValue
        return Button {
            selectedColorRaw = choice.rawValue
            Haptics.light()
        } label: {
            VStack(spacing: 5) {
                swatch(for: choice)
                    .frame(width: 28, height: 28)
                    // The custom swatch carries an invisible system
                    // ColorPicker: tapping the circle opens the color wheel;
                    // tapping the rest of the cell just selects the stored
                    // custom color.
                    .overlay {
                        if choice == .custom {
                            ColorPicker("", selection: $customPickerColor, supportsOpacity: false)
                                .labelsHidden()
                                .opacity(0.02)
                                .onChange(of: customPickerColor) { _, newColor in
                                    if let hex = newColor.burnbarHexString {
                                        customColorHex = hex
                                    }
                                    selectedColorRaw = HermesThinkingColorChoice.custom.rawValue
                                }
                        }
                    }
                Text(choice.displayName)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectionFill(isSelected, cornerRadius: 13))
            .overlay(selectionStroke(isSelected, cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.displayName) spinner color")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func swatch(for choice: HermesThinkingColorChoice) -> some View {
        switch choice {
        case .mono:
            // Half black / half white — reads as "black & white" at a glance.
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0.5),
                            .init(color: .black, location: 0.5)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(Circle().stroke(MobileTheme.Colors.border.opacity(0.6), lineWidth: 0.75))
        case .mercury:
            Circle().fill(AuroraDesign.Gradients.mercuryFoil)
        case .rainbow:
            Circle().fill(
                AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                    center: .center
                )
            )
        case .custom:
            Circle()
                .fill(Color(hex: customColorHex))
                .overlay(
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                )
        default:
            Circle().fill(
                choice.shapeStyle(
                    date: .now,
                    provider: provider,
                    modelName: modelName,
                    customHex: customColorHex,
                    reduceMotion: true
                )
            )
        }
    }

    // MARK: Size cells

    private func sizeCell(_ choice: HermesThinkingSizeChoice) -> some View {
        let isSelected = selectedSizeRaw == choice.rawValue
        return Button {
            selectedSizeRaw = choice.rawValue
            Haptics.light()
        } label: {
            VStack(spacing: 4) {
                Text("⠿")
                    .font(.system(size: choice.pointSize, design: .monospaced))
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                    .frame(height: 36)
                Text(choice.displayName)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectionFill(isSelected, cornerRadius: 13))
            .overlay(selectionStroke(isSelected, cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.displayName) spinner size")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Selection chrome

    private func selectionFill(_ isSelected: Bool, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isSelected ? MobileTheme.hermesAureate.opacity(0.14) : MobileTheme.Colors.surface.opacity(0.7))
    }

    private func selectionStroke(_ isSelected: Bool, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                isSelected ? MobileTheme.hermesAureate.opacity(0.6) : MobileTheme.Colors.border.opacity(0.3),
                lineWidth: isSelected ? 1 : 0.5
            )
    }
}

// MARK: - Color → hex

private extension Color {
    /// sRGB "RRGGBB" export for persisting the custom picker color.
    var burnbarHexString: String? {
        guard let components = UIColor(self).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        )?.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Previews

#Preview("Spinner") {
    VStack(spacing: 16) {
        ForEach([HermesThinkingStyle.braille, .scan, .cascade, .dna]) { style in
            HermesThinkingSpinner(styleOverride: style, colorOverride: .rainbow)
        }
        HermesThinkingSpinner(styleOverride: .droplets, sizeOverride: .large)
    }
    .padding()
    .background(MobileTheme.Colors.background)
}

#Preview("Picker") {
    HermesThinkingStylePickerSheet()
}
