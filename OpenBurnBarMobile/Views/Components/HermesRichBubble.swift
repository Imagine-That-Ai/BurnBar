import SwiftUI
import OpenBurnBarCore
import UIKit

// MARK: - HermesRichBubble (iOS)
//
// One assistant message rendered with full atom-aware layout. Three things
// happen here:
//
//   1. `HermesAtomParser.parse(text)` splits the message into a typed run
//      stream: body / atom / mention / code.
//   2. The runs are converted into `PretextRichInlineItem`s and handed to
//      pretext rich-inline. Pretext returns line groupings that respect
//      atomic chips (chips never break across lines) and prose flow.
//   3. We render each fragment as a native SwiftUI view: body = Text,
//      mention/code = chrome-styled Text, atom = `HermesAtomChip` with
//      navigator dispatch.
//
// Streaming / error / empty messages fall through to a plain `Text`
// fallback so we never block on engine readiness for the first paint.

struct HermesRichBubble: View {
    /// Source text. For Hermes-emitted markdown links this should be the
    /// raw assistant content (the parser handles the link extraction).
    let text: String
    /// Body font size in points. Atom chips inherit a slightly smaller size.
    var baseSize: CGFloat = 15
    /// Color applied to body text.
    var baseColor: Color = MobileTheme.Colors.textPrimary
    /// Color applied to mention text.
    var mentionColor: Color = MobileTheme.hermesAureate
    /// Color applied to inline code text.
    var codeColor: Color = MobileTheme.Colors.textPrimary
    /// Background fill for code spans.
    var codeBackground: Color = MobileTheme.Colors.surfaceElevated
    /// Line height in CSS pixels. Defaults to baseSize × 1.36 if unset.
    var lineHeight: CGFloat?

    @State private var runs: [HermesRichRun] = []
    @State private var lines: [PretextRichLine] = []
    @State private var measuredAt: CGFloat? = nil

    @Environment(\.hermesAtomNavigator) private var navigator

    private var resolvedLineHeight: CGFloat {
        lineHeight ?? (baseSize * 1.36)
    }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(height: estimatedHeight)
    }

    private var estimatedHeight: CGFloat {
        let lineCount = max(lines.count, fallbackLineEstimate)
        return CGFloat(lineCount) * resolvedLineHeight
    }

    /// Heuristic used before the engine has measured anything — gives the
    /// bubble a roughly correct frame on first render.
    private var fallbackLineEstimate: Int {
        let charsPerLine = 50.0
        return max(1, Int((Double(text.count) / charsPerLine).rounded(.up)))
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if lines.isEmpty {
            attributedFallback(width: width)
                .task(id: measureKey(width: width)) { await measure(at: width) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(Array(line.fragments.enumerated()), id: \.offset) { _, fragment in
                            renderedFragment(fragment)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: resolvedLineHeight, alignment: .leading)
                    .frame(maxWidth: width, alignment: .leading)
                }
            }
            .frame(maxWidth: width, alignment: .leading)
            .task(id: measureKey(width: width)) { await measure(at: width) }
        }
    }

    @ViewBuilder
    private func renderedFragment(_ fragment: PretextRichFragment) -> some View {
        if fragment.itemIndex < runs.count {
            let run = runs[fragment.itemIndex]
            switch run.kind {
            case .body(let style):
                Text(fragment.text)
                    .font(.system(
                        size: baseSize,
                        weight: style.contains(.bold) ? .semibold : .regular,
                        design: .rounded
                    ))
                    .italic(style.contains(.italic))
                    .strikethrough(style.contains(.strikethrough))
                    .foregroundStyle(baseColor)
                    .padding(.leading, fragment.gapBefore)

            case .atom(let atom, let label):
                HermesAtomChip(
                    atom: atom,
                    label: label,
                    size: .inline(baseSize: baseSize)
                )
                .padding(.leading, fragment.gapBefore)

            case .mention(let handle):
                Text(handle)
                    .font(.system(size: baseSize - 1, weight: .semibold, design: .rounded))
                    .foregroundStyle(mentionColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mentionColor.opacity(0.12))
                    )
                    .padding(.leading, fragment.gapBefore)

            case .code:
                Text(fragment.text)
                    .font(.system(size: baseSize - 1, weight: .medium, design: .monospaced))
                    .foregroundStyle(codeColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(codeBackground.opacity(0.85))
                    )
                    .padding(.leading, fragment.gapBefore)
            }
        } else {
            // Defensive — should never happen, but render text rather than
            // crash if pretext returns an out-of-range itemIndex.
            Text(fragment.text)
                .font(.system(size: baseSize, weight: .regular, design: .rounded))
                .foregroundStyle(baseColor)
                .padding(.leading, fragment.gapBefore)
        }
    }

    @ViewBuilder
    private func attributedFallback(width: CGFloat) -> some View {
        Text(buildAttributedFallback())
            .font(.system(size: baseSize, weight: .regular, design: .rounded))
            .foregroundStyle(baseColor)
            .frame(maxWidth: width, alignment: .leading)
            .lineSpacing(max(0, resolvedLineHeight - baseSize - 4))
    }

    private func buildAttributedFallback() -> AttributedString {
        let parsedRuns = HermesAtomParser.parse(text)
        let attr = NSMutableAttributedString()
        for run in parsedRuns {
            attr.append(NSAttributedString(
                string: run.text,
                attributes: nsAttributes(for: run.kind)
            ))
        }
        return AttributedString(attr)
    }

    private func nsAttributes(for kind: HermesRichRunKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .body(let style):
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor(baseColor)
            ]
            if !style.isDisjoint(with: [.bold, .italic]) {
                attributes[.font] = Self.roundedUIFont(
                    size: baseSize,
                    weight: style.contains(.bold) ? .semibold : .regular,
                    italic: style.contains(.italic)
                )
            }
            if style.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        case .atom(_, _):
            return [
                .foregroundColor: UIColor(MobileTheme.hermesAureate),
                .font: Self.roundedUIFont(size: baseSize - 1, weight: .semibold)
            ]
        case .mention(_):
            return [
                .foregroundColor: UIColor(mentionColor),
                .font: Self.roundedUIFont(size: baseSize - 1, weight: .semibold)
            ]
        case .code:
            return [
                .foregroundColor: UIColor(codeColor),
                .font: UIFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .medium)
            ]
        }
    }

    private static func roundedUIFont(size: CGFloat, weight: UIFont.Weight, italic: Bool = false) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        if italic, let italicDescriptor = descriptor.withSymbolicTraits(
            descriptor.symbolicTraits.union(.traitItalic)
        ) {
            descriptor = italicDescriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Measurement

    private func measureKey(width: CGFloat) -> String {
        "\(text.hashValue)|\(baseSize)|\(width)|\(resolvedLineHeight)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        let parsed = HermesAtomParser.parse(text)
        let items = parsed.map { Self.toPretextItem($0, baseSize: baseSize) }
        guard !items.isEmpty else { return }
        do {
            let engine = PretextEngine.shared
            let handle = try await engine.prepareRichInline(items: items)
            let resolved = try await engine.layoutRichInline(handle: handle, maxWidth: width)
            await engine.release(handle: handle)
            await MainActor.run {
                self.runs = parsed
                self.lines = resolved
                self.measuredAt = width
            }
        } catch {
            // Engine unavailable — keep AttributedString fallback.
        }
    }

    /// Convert a typed run into the pretext input that mirrors its visual
    /// chrome. `extraWidth` here matches the chip's horizontal padding × 2
    /// in the renderers above so wrap math equals visual reality.
    private static func toPretextItem(
        _ run: HermesRichRun,
        baseSize: CGFloat
    ) -> PretextRichInlineItem {
        switch run.kind {
        case .body(let style):
            // Mirror the rendered weight/slant so wrap math equals visual
            // reality — semibold glyphs run wider than regular ones.
            let weight = style.contains(.bold) ? 600 : 400
            let slant = style.contains(.italic) ? "italic " : ""
            return PretextRichInlineItem(
                text: run.text,
                font: "\(slant)\(weight) \(Int(baseSize))px -apple-system"
            )
        case .atom:
            return PretextRichInlineItem(
                text: run.text,
                font: "600 \(Int(max(11, baseSize - 1)))px -apple-system",
                breakNever: true,
                // 7pt horizontal padding × 2 + ~12pt for icon + 4pt gap.
                extraWidth: 14 + 12 + 4
            )
        case .mention:
            return PretextRichInlineItem(
                text: run.text,
                font: "600 \(Int(baseSize - 1))px -apple-system",
                breakNever: true,
                extraWidth: 12
            )
        case .code:
            return PretextRichInlineItem(
                text: run.text,
                font: "500 \(Int(baseSize - 1))px ui-monospace, Menlo, monospace",
                extraWidth: 10
            )
        }
    }
}

// MARK: - Preview

#Preview {
    HermesRichBubble(
        text: """
        Today you spent [$2.34 today](burnbar://burn?window=today&amount=2.34) across 3 sessions, mostly on [Claude Sonnet 4.7](burnbar://model?id=claude-sonnet-4.7).

        Your biggest run used [12.4k tokens](burnbar://tokens?value=12400&scope=session) and called `ReadFile` six times. [Anthropic](burnbar://provider?token=anthropic) is at [78% quota](burnbar://quota?provider=anthropic&percent=78). Open [session abc-123](burnbar://session?id=abc-123) for the diff.
        """
    )
    .padding()
    .background(MobileTheme.Colors.surface)
}
