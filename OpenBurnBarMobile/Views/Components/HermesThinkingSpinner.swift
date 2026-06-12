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

// MARK: - Hermes Thinking Glyph

/// Which brand mark(s) the Swarm style forms. `agent` is the runtime that
/// owns the chat (Hermes, Claude Code, Codex…); `model` is the provider
/// behind the routed model (MiniMax, OpenAI…); `both` alternates — one mark,
/// back to dots, then the other.
enum HermesThinkingGlyphChoice: String, CaseIterable, Identifiable {
    case agent
    case model
    case both
    case burnbar

    static let storageKey = "hermesThinkingGlyph"
    static let defaultChoice: HermesThinkingGlyphChoice = .agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agent:   return "Agent"
        case .model:   return "Model"
        case .both:    return "Agent ⇄ Model"
        case .burnbar: return "BurnBar"
        }
    }
}

// MARK: - Hermes Thinking Glyph Count

/// How many bouncing glyph formations the Swarm style shows. One keeps the
/// original glyph ⇄ dots morph cycle; two and three render side-by-side
/// formations that bounce like a typing indicator.
enum HermesThinkingGlyphCountChoice: String, CaseIterable, Identifiable {
    case one
    case two
    case three

    static let storageKey = "hermesThinkingGlyphCount"
    static let defaultChoice: HermesThinkingGlyphCountChoice = .three

    var id: String { rawValue }

    var slots: Int {
        switch self {
        case .one:   return 1
        case .two:   return 2
        case .three: return 3
        }
    }

    var displayName: String {
        switch self {
        case .one:   return "One"
        case .two:   return "Two"
        case .three: return "Three"
        }
    }
}

// MARK: - Hermes Thinking Bounce

/// Motion personality for multi-glyph swarm formations.
enum HermesThinkingBounceChoice: String, CaseIterable, Identifiable {
    case wave
    case pulse
    case breathe
    case sway
    case still

    static let storageKey = "hermesThinkingBounce"
    static let defaultChoice: HermesThinkingBounceChoice = .wave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wave:    return "Wave"
        case .pulse:   return "Pulse"
        case .breathe: return "Breathe"
        case .sway:    return "Sway"
        case .still:   return "Still"
        }
    }
}

// MARK: - Swarm Glyph Source

/// What a swarm slot forms: a provider's brand mark or the BurnBar mark.
enum HermesSwarmGlyphSource: Equatable {
    case provider(AgentProvider)
    case burnbar

    @MainActor
    func points(maxPoints: Int) -> [SwarmGlyphPoint] {
        switch self {
        case .provider(let provider):
            return SwarmGlyphSampler.glyphPoints(for: provider, maxPoints: maxPoints)
        case .burnbar:
            return SwarmGlyphSampler.burnBarGlyphPoints(maxPoints: maxPoints)
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
    @AppStorage(HermesThinkingGlyphChoice.storageKey)
    private var glyphChoiceRaw: String = HermesThinkingGlyphChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingGlyphCountChoice.storageKey)
    private var glyphCountRaw: String = HermesThinkingGlyphCountChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingBounceChoice.storageKey)
    private var bounceRaw: String = HermesThinkingBounceChoice.defaultChoice.rawValue
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

    /// The marks the Swarm style forms, per the user's glyph choice. Falls
    /// back to the agent mark when no model is routed (or both resolve to
    /// the same brand).
    private var swarmGlyphSources: [HermesSwarmGlyphSource] {
        let agent = provider ?? .hermes
        let model: AgentProvider? = modelName.flatMap { name in
            name.isEmpty ? nil : hermesAgentProvider(for: name)
        }
        switch HermesThinkingGlyphChoice(rawValue: glyphChoiceRaw) ?? .defaultChoice {
        case .agent:
            return [.provider(agent)]
        case .model:
            return [.provider(model ?? agent)]
        case .both:
            guard let model, model != agent else { return [.provider(agent)] }
            return [.provider(agent), .provider(model)]
        case .burnbar:
            return [.burnbar]
        }
    }

    var body: some View {
        Group {
            if style == .swarm {
                SwarmDotsThinkingIndicator(
                    sources: swarmGlyphSources,
                    slots: (HermesThinkingGlyphCountChoice(rawValue: glyphCountRaw) ?? .defaultChoice).slots,
                    bounce: HermesThinkingBounceChoice(rawValue: bounceRaw) ?? .defaultChoice,
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
    /// What the slots form. One source fills every slot; two alternate
    /// across slots (A M A) — and across cycles in single-slot mode.
    let sources: [HermesSwarmGlyphSource]
    /// How many side-by-side formations to render. One slot keeps the
    /// original glyph ⇄ dots morph; multiple slots bounce continuously.
    let slots: Int
    let bounce: HermesThinkingBounceChoice
    /// 1.0 at medium; scales the whole stage.
    let scale: CGFloat
    /// True for the "authentic" color treatments (Subtle/Provider): marks
    /// show the logo's real sampled colors, crossfading to the user's
    /// shading while scattered. Explicit color picks rule the whole cycle.
    let usesBrandGlyphColors: Bool
    /// Resolves the user's color choice at a moment in time (rainbow cycles).
    let shading: (Date) -> AnyShapeStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slotClouds: [[SwarmGlyphPoint]] = []
    @State private var appearedAt = Date()

    // Single-slot cycle: glyph hold → scatter to dots → dots hold → reform.
    private static let period: Double = 4.6
    private static let glyphHoldEnd: Double = 1.5
    private static let toDotsEnd: Double = 2.3
    private static let dotsHoldEnd: Double = 3.8
    /// Multi-slot entrance: particles converge over this window.
    private static let convergeDuration: Double = 0.9

    private var slotCount: Int { max(1, slots) }
    private var isMultiSlot: Bool { slotCount > 1 }

    private var stageSize: CGSize {
        isMultiSlot
            ? CGSize(width: (34 * CGFloat(slotCount) + 6) * scale, height: 44 * scale)
            : CGSize(width: 92 * scale, height: 40 * scale)
    }

    /// Per-slot particle budget — denser when there is only one formation.
    private var pointBudget: Int { isMultiSlot ? 72 : 120 }

    private var slotSources: [HermesSwarmGlyphSource] {
        guard !sources.isEmpty else { return [.provider(.hermes)] }
        return (0..<slotCount).map { sources[$0 % sources.count] }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { graphics, size in
                draw(in: &graphics, size: size, date: context.date)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .onAppear {
            appearedAt = Date()
            reloadClouds()
        }
        .onChange(of: sources) { _, _ in reloadClouds() }
        .onChange(of: slots) { _, _ in reloadClouds() }
    }

    private func reloadClouds() {
        // Multi-slot: one cloud per visible slot. Single-slot: load every
        // source so the morph cycle can alternate marks (Agent ⇄ Model).
        let wanted = isMultiSlot ? slotSources : sources
        slotClouds = wanted.map { $0.points(maxPoints: pointBudget) }
    }

    // MARK: Drawing

    private func draw(in graphics: inout GraphicsContext, size: CGSize, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        let userStyle = shading(date)

        if isMultiSlot {
            let sinceAppear = date.timeIntervalSince(appearedAt)
            let pitch = size.width / CGFloat(slotCount)
            for slot in 0..<slotCount {
                let cloud = slotCloud(slot)
                let slotPhase = Double(slot) * 0.7
                // Entrance: each slot converges with a slight stagger.
                let entrance = reduceMotion ? 0 : (1 - Self.smoothstep(
                    (sinceAppear - Double(slot) * 0.12) / Self.convergeDuration
                ))
                var center = CGPoint(
                    x: pitch * (CGFloat(slot) + 0.5),
                    y: size.height * 0.56
                )
                var radius = 13 * scale
                var opacityMul = 1.0
                if !reduceMotion {
                    switch bounce {
                    case .wave:
                        let lift = pow(max(0, sin(t * 2 * .pi / 1.15 - slotPhase)), 2)
                        center.y -= CGFloat(lift) * 6 * scale
                    case .pulse:
                        radius *= 1 + 0.14 * CGFloat(sin(t * 2 * .pi / 1.3 - slotPhase))
                    case .breathe:
                        opacityMul = 0.68 + 0.32 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.2 - slotPhase))
                        radius *= 1 + 0.05 * CGFloat(sin(t * 2 * .pi / 2.2 - slotPhase))
                    case .sway:
                        center.x += CGFloat(sin(t * 2 * .pi / 1.6 - slotPhase)) * 3.5 * scale
                    case .still:
                        break
                    }
                }
                drawFormation(
                    cloud: cloud,
                    in: &graphics,
                    center: center,
                    glyphRadius: radius,
                    scatter: entrance,
                    scatterTarget: { _, _ in center },
                    scatterSpread: max(size.width, size.height) * 0.6,
                    opacityMul: opacityMul,
                    t: t,
                    userStyle: userStyle
                )
            }
            return
        }

        // Single slot: original glyph ⇄ dots morph cycle (with two sources,
        // the end-of-cycle return targets the NEXT mark).
        let phase = t.truncatingRemainder(dividingBy: Self.period)
        let cycle = Int((t / Self.period).rounded(.down))
        let clouds = slotClouds.filter { !$0.isEmpty }
        let cycleClouds = clouds.isEmpty ? [Self.fallbackRing] : clouds
        let active = ((cycle % cycleClouds.count) + cycleClouds.count) % cycleClouds.count
        let cloudIndex = (cycleClouds.count > 1 && phase >= Self.dotsHoldEnd)
            ? (active + 1) % cycleClouds.count
            : active
        let cloud = cycleClouds[cloudIndex]

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let glyphRadius = min(size.width, size.height) * 0.47
        let dotSpread = size.width * 0.29
        let dotClusterRadius = 2.6 * scale
        let clusterCenters: [CGPoint] = [
            CGPoint(x: center.x - dotSpread, y: center.y),
            center,
            CGPoint(x: center.x + dotSpread, y: center.y)
        ]
        let count = cloud.count
        let perCluster = Double((count + 2) / 3)

        var bounceLift: CGFloat = 0
        if !reduceMotion, bounce == .wave {
            bounceLift = CGFloat(pow(max(0, sin(t * 2 * .pi / 1.15)), 2)) * 4 * scale
        }

        let m: (Int) -> Double = { index in
            if self.reduceMotion { return 1 }
            let stagger = Self.unitHash(index, salt: 1) * 0.35
            if phase < Self.glyphHoldEnd { return 0 }
            if phase < Self.toDotsEnd {
                return Self.smoothstep((phase - Self.glyphHoldEnd - stagger) / (Self.toDotsEnd - Self.glyphHoldEnd - 0.35))
            }
            if phase < Self.dotsHoldEnd { return 1 }
            return 1 - Self.smoothstep((phase - Self.dotsHoldEnd - stagger) / (Self.period - Self.dotsHoldEnd - 0.35))
        }

        drawMorph(
            cloud: cloud,
            in: &graphics,
            glyphCenter: CGPoint(x: center.x, y: center.y - bounceLift),
            glyphRadius: glyphRadius,
            morph: m,
            dotTarget: { index in
                let clusterIndex = index % 3
                let u = (Double(index / 3) + 0.5) / perCluster
                let spiralRadius = dotClusterRadius * sqrt(u)
                let spiralAngle = Double(index) * 2.39996323
                return CGPoint(
                    x: clusterCenters[clusterIndex].x + cos(spiralAngle) * spiralRadius,
                    y: clusterCenters[clusterIndex].y + sin(spiralAngle) * spiralRadius
                )
            },
            t: t,
            userStyle: userStyle
        )
    }

    private func slotCloud(_ slot: Int) -> [SwarmGlyphPoint] {
        guard slot < slotClouds.count, !slotClouds[slot].isEmpty else { return Self.fallbackRing }
        return slotClouds[slot]
    }

    /// Draws one formation. `scatter` ∈ [0, 1]: 0 = fully formed, 1 = blown
    /// out toward deterministic scatter positions (used for the entrance).
    private func drawFormation(
        cloud: [SwarmGlyphPoint],
        in graphics: inout GraphicsContext,
        center: CGPoint,
        glyphRadius: CGFloat,
        scatter: Double,
        scatterTarget: (Int, CGPoint) -> CGPoint,
        scatterSpread: CGFloat,
        opacityMul: Double,
        t: Double,
        userStyle: AnyShapeStyle
    ) {
        for index in 0..<cloud.count {
            let hashA = Self.unitHash(index, salt: 1)
            let hashB = Self.unitHash(index, salt: 2)
            let point = cloud[index]
            let formed = CGPoint(
                x: center.x + point.position.x * glyphRadius,
                y: center.y + point.position.y * glyphRadius
            )
            let scattered = CGPoint(
                x: center.x + CGFloat(hashA - 0.5) * scatterSpread * 2,
                y: center.y + CGFloat(hashB - 0.5) * scatterSpread * 2
            )
            let s = scatter
            let chaos = reduceMotion ? 0 : (0.22 + 9.0 * s * (1 - s)) * scale
            let wobbleX = sin(t * (1.3 + hashA * 1.4) + hashB * .pi * 2) * chaos
            let wobbleY = cos(t * (1.1 + hashB * 1.6) + hashA * .pi * 2) * chaos
            let position = CGPoint(
                x: formed.x + (scattered.x - formed.x) * s + wobbleX,
                y: formed.y + (scattered.y - formed.y) * s + wobbleY
            )
            let radius = (0.74 + 0.32 * hashB) * scale
            let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
            let path = Path(ellipseIn: rect)
            let baseOpacity = (0.78 + 0.22 * hashA) * opacityMul

            if usesBrandGlyphColors, let brand = point.brandColor {
                if s < 1 {
                    graphics.opacity = baseOpacity * (1 - s) * brand.a
                    graphics.fill(path, with: .color(brand.color))
                }
                if s > 0 {
                    graphics.opacity = baseOpacity * s
                    graphics.fill(path, with: .style(userStyle))
                }
            } else {
                graphics.opacity = baseOpacity
                graphics.fill(path, with: .style(userStyle))
            }
        }
    }

    /// Single-slot morph between glyph formation and the three-dot pools.
    private func drawMorph(
        cloud: [SwarmGlyphPoint],
        in graphics: inout GraphicsContext,
        glyphCenter: CGPoint,
        glyphRadius: CGFloat,
        morph: (Int) -> Double,
        dotTarget: (Int) -> CGPoint,
        t: Double,
        userStyle: AnyShapeStyle
    ) {
        for index in 0..<cloud.count {
            let hashA = Self.unitHash(index, salt: 1)
            let hashB = Self.unitHash(index, salt: 2)
            let point = cloud[index]
            let m = morph(index)
            let glyphTarget = CGPoint(
                x: glyphCenter.x + point.position.x * glyphRadius,
                y: glyphCenter.y + point.position.y * glyphRadius
            )
            let dots = dotTarget(index)
            let chaos = reduceMotion ? 0 : (0.22 + 9.0 * m * (1 - m)) * scale
            let wobbleX = sin(t * (1.3 + hashA * 1.4) + hashB * .pi * 2) * chaos
            let wobbleY = cos(t * (1.1 + hashB * 1.6) + hashA * .pi * 2) * chaos
            let position = CGPoint(
                x: glyphTarget.x + (dots.x - glyphTarget.x) * m + wobbleX,
                y: glyphTarget.y + (dots.y - glyphTarget.y) * m + wobbleY
            )
            let radius = (0.74 + 0.32 * hashB + 1.05 * m) * scale
            let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
            let path = Path(ellipseIn: rect)
            let baseOpacity = 0.78 + 0.22 * hashA

            if usesBrandGlyphColors, let brand = point.brandColor {
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
    private static let fallbackRing: [SwarmGlyphPoint] = (0..<120).map { index in
        let angle = Double(index) / 120.0 * .pi * 2
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
    @AppStorage(HermesThinkingGlyphChoice.storageKey)
    private var glyphChoiceRaw: String = HermesThinkingGlyphChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingGlyphCountChoice.storageKey)
    private var glyphCountRaw: String = HermesThinkingGlyphCountChoice.defaultChoice.rawValue
    @AppStorage(HermesThinkingBounceChoice.storageKey)
    private var bounceRaw: String = HermesThinkingBounceChoice.defaultChoice.rawValue
    @State private var customPickerColor = Color(hex: "FF9F0A")
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
                    if selectedStyleRaw == HermesThinkingStyle.swarm.rawValue {
                        section("Glyph") {
                            LazyVGrid(columns: colorColumns, spacing: 10) {
                                ForEach(HermesThinkingGlyphChoice.allCases) { choice in
                                    glyphCell(choice)
                                }
                            }
                        }
                        section("Glyphs") {
                            HStack(spacing: 10) {
                                ForEach(HermesThinkingGlyphCountChoice.allCases) { choice in
                                    countCell(choice)
                                }
                            }
                        }
                        section("Bounce") {
                            HStack(spacing: 10) {
                                ForEach(HermesThinkingBounceChoice.allCases) { choice in
                                    bounceCell(choice)
                                }
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

    // MARK: Glyph cells

    /// The model-side brand mark, derived the same way the spinner does it.
    private var modelGlyphProvider: AgentProvider? {
        modelName.flatMap { name in
            name.isEmpty ? nil : hermesAgentProvider(for: name)
        }
    }

    private func glyphCell(_ choice: HermesThinkingGlyphChoice) -> some View {
        let isSelected = glyphChoiceRaw == choice.rawValue
        let agent = provider ?? .hermes
        return Button {
            glyphChoiceRaw = choice.rawValue
            Haptics.light()
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    switch choice {
                    case .agent:
                        UnifiedProviderLogoView(provider: agent, size: 22, useFallbackColor: true)
                    case .model:
                        UnifiedProviderLogoView(provider: modelGlyphProvider ?? agent, size: 22, useFallbackColor: true)
                    case .both:
                        UnifiedProviderLogoView(provider: agent, size: 18, useFallbackColor: true)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        UnifiedProviderLogoView(provider: modelGlyphProvider ?? agent, size: 18, useFallbackColor: true)
                    case .burnbar:
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MobileTheme.ember)
                    }
                }
                .frame(height: 24)
                Text(choice.displayName)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectionFill(isSelected, cornerRadius: 13))
            .overlay(selectionStroke(isSelected, cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.displayName) swarm glyph")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func countCell(_ choice: HermesThinkingGlyphCountChoice) -> some View {
        let isSelected = glyphCountRaw == choice.rawValue
        return Button {
            glyphCountRaw = choice.rawValue
            Haptics.light()
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(0..<choice.slots, id: \.self) { _ in
                        Circle()
                            .fill(isSelected ? MobileTheme.hermesAureate : MobileTheme.Colors.textMuted)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(height: 20)
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
        .accessibilityLabel("\(choice.displayName) glyph formations")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func bounceCell(_ choice: HermesThinkingBounceChoice) -> some View {
        let isSelected = bounceRaw == choice.rawValue
        return Button {
            bounceRaw = choice.rawValue
            Haptics.light()
        } label: {
            Text(choice.displayName)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selectionFill(isSelected, cornerRadius: 13))
                .overlay(selectionStroke(isSelected, cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.displayName) bounce")
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
