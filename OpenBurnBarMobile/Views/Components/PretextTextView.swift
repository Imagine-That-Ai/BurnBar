import SwiftUI
import OpenBurnBarCore

// MARK: - PretextTextView
//
// Renders multi-line text using `PretextEngine` for line-breaking and
// height calculation, then composes each line with a native SwiftUI `Text`.
//
// Why hybrid (pretext layout + native text rendering):
// - Native `Text` keeps Dynamic Type, accessibility traits, copy/paste,
//   and high-fidelity Apple typography (kerning, ligatures).
// - Pretext gives us the exact wrap points and shrink-wrap width up front,
//   without forcing a layout pass first.
//
// While pretext is preparing measurements (first call for `text`+`font`),
// we render the input as plain `Text` so the user never sees a flicker.

struct PretextTextView: View {
    /// Text content. Full unicode supported.
    let text: String
    /// Canvas font string, e.g. `"500 14px -apple-system"`. Must match the
    /// SwiftUI `font(_:)` we pass to the rendered `Text` so wrap points line up.
    let canvasFont: String
    /// SwiftUI font used to render each line.
    let font: Font
    /// CSS-pixel line height. Pass the same value you'd give `lineSpacing`-aware
    /// callers; gets used both for measurement and the per-line frame height.
    let lineHeight: CGFloat
    /// Width to wrap at. `nil` means "use available width". When nil, we fall
    /// back to `GeometryReader` to obtain it at render time.
    let maxWidth: CGFloat?
    /// Color applied to each rendered line.
    var color: Color = MobileTheme.Colors.textPrimary
    /// Pretext options (whiteSpace / wordBreak / letterSpacing).
    var options: PretextOptions = .normal
    /// When true, runs a binary search to find the tightest container width
    /// that keeps the rendered line count ≤ `shrinkTargetLines`. Useful for
    /// chat bubbles where you want the text to not span the full bubble width
    /// when a tighter wrap is more pleasant.
    var shrink: Bool = false
    /// Target line count when `shrink` is enabled.
    var shrinkTargetLines: Int = 3

    @State private var resolvedLines: [PretextLine] = []
    @State private var resolvedHeight: CGFloat? = nil
    @State private var resolvedWidth: CGFloat? = nil
    @State private var measureToken: UUID = UUID()

    var body: some View {
        Group {
            if let maxWidth {
                content(width: maxWidth)
            } else {
                GeometryReader { proxy in
                    content(width: proxy.size.width)
                }
                // GeometryReader has no intrinsic height, so we must pin one.
                .frame(height: resolvedHeight ?? estimateNativeHeight())
            }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if resolvedLines.isEmpty {
            // First-paint fallback: native Text. Once pretext catches up,
            // we swap in the per-line rendering below.
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .frame(maxWidth: width, alignment: .leading)
                .task(id: measureKey(width: width)) {
                    await measure(at: width)
                }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(resolvedLines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(font)
                        .foregroundStyle(color)
                        .frame(height: lineHeight, alignment: .leading)
                        .frame(maxWidth: resolvedWidth ?? width, alignment: .leading)
                }
            }
            .frame(width: resolvedWidth ?? width, alignment: .leading)
            .task(id: measureKey(width: width)) {
                await measure(at: width)
            }
        }
    }

    // MARK: - Measurement

    private func measureKey(width: CGFloat) -> String {
        // Re-measure when input contract changes.
        "\(text.hashValue)|\(canvasFont)|\(width)|\(lineHeight)|\(shrink ? 1 : 0)|\(shrinkTargetLines)|\(measureToken)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        do {
            let engine = PretextEngine.shared
            let prepared = try await engine.prepareWithSegments(
                text: text,
                font: canvasFont,
                options: options
            )
            let targetWidth: CGFloat
            if shrink {
                targetWidth = try await engine.shrinkWrapWidth(
                    handle: prepared,
                    upper: width,
                    targetLines: shrinkTargetLines
                )
            } else {
                targetWidth = width
            }
            let result = try await engine.layoutWithLines(
                handle: prepared,
                maxWidth: targetWidth,
                lineHeight: lineHeight
            )
            await MainActor.run {
                self.resolvedLines = result.lines
                self.resolvedHeight = result.height
                self.resolvedWidth = targetWidth
            }
        } catch {
            // Engine unavailable: keep the native `Text` fallback rendered.
        }
    }

    /// Approximate height when we don't have a measured value yet — used so
    /// `GeometryReader`-wrapped instances reserve a sensible row height before
    /// the first pretext callback resolves.
    private func estimateNativeHeight() -> CGFloat {
        // 2 lines is a reasonable default; once measurement lands the frame
        // resizes to the actual height.
        lineHeight * 2
    }
}

// MARK: - Convenience initializers

extension PretextTextView {
    /// Convenience: build the canvas font string from a SwiftUI font size +
    /// weight pairing. We default to `-apple-system` to match SF on iOS.
    init(
        _ text: String,
        size: CGFloat,
        weight: PretextFontWeight = .regular,
        color: Color = MobileTheme.Colors.textPrimary,
        lineHeight: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        shrink: Bool = false,
        shrinkTargetLines: Int = 3,
        options: PretextOptions = .normal
    ) {
        self.text = text
        self.canvasFont = "\(weight.canvasValue) \(Int(size))px -apple-system"
        self.font = .system(size: size, weight: weight.swiftUIValue, design: .rounded)
        self.lineHeight = lineHeight ?? (size * 1.32)
        self.maxWidth = maxWidth
        self.color = color
        self.shrink = shrink
        self.shrinkTargetLines = shrinkTargetLines
        self.options = options
    }
}

/// Weight wrapper that knows both its CSS canvas-font value and its
/// SwiftUI counterpart.
enum PretextFontWeight: Hashable {
    case regular
    case medium
    case semibold
    case bold

    var canvasValue: String {
        switch self {
        case .regular:  return "400"
        case .medium:   return "500"
        case .semibold: return "600"
        case .bold:     return "700"
        }
    }

    var swiftUIValue: Font.Weight {
        switch self {
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        case .bold:     return .bold
        }
    }
}
