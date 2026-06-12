import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Thinking Style

/// User-selectable "Hermes is thinking" animation. One legacy mercury-droplet
/// style plus a full deck of braille spinners (the `unicode-animations` set).
/// Style, color, and size persist app-wide via `@AppStorage` and render
/// through `HermesThinkingSpinner`, so every thinking surface (Hermes chat,
/// Quick Ask, Agent Live Stage, Chart Studio) follows the same preference.
enum HermesThinkingStyle: String, CaseIterable, Identifiable {
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
    static let defaultStyle: HermesThinkingStyle = .braille

    var id: String { rawValue }

    var displayName: String {
        switch self {
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
            if style == .droplets {
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
