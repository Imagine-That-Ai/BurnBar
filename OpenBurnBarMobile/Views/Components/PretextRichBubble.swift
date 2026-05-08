import SwiftUI
import OpenBurnBarCore

// MARK: - PretextRichBubble
//
// Renders text with mixed inline styling (mentions, code spans, plain prose)
// using `@chenglou/pretext/rich-inline` for line breaking, then composes
// each fragment with native SwiftUI `Text` for fidelity and accessibility.
//
// We parse the source string into `RichRun`s — atomic typed fragments — and
// hand them to pretext, which knows how to break a sequence of mixed-font
// items into clean lines. Pretext returns line groupings; we recover the
// original `RichRun` per fragment via `itemIndex`.
//
// Supported markup (kept narrow on purpose):
//   - `@handle` → mention chip, atomic, semibold accent color
//   - `` `code` `` → mono span (treated as one chip when short, splittable when long)
//   - everything else → body run

struct PretextRichBubble: View {
    let text: String
    let baseSize: CGFloat
    let baseColor: Color
    let mentionColor: Color
    let codeColor: Color
    let codeBackground: Color
    let lineHeight: CGFloat

    init(
        text: String,
        baseSize: CGFloat = 15,
        baseColor: Color = MobileTheme.Colors.textPrimary,
        mentionColor: Color = MobileTheme.hermesAureate,
        codeColor: Color = MobileTheme.Colors.textPrimary,
        codeBackground: Color = MobileTheme.Colors.surfaceElevated,
        lineHeight: CGFloat? = nil
    ) {
        self.text = text
        self.baseSize = baseSize
        self.baseColor = baseColor
        self.mentionColor = mentionColor
        self.codeColor = codeColor
        self.codeBackground = codeBackground
        self.lineHeight = lineHeight ?? (baseSize * 1.36)
    }

    @State private var lines: [PretextRichLine] = []
    @State private var runs: [RichRun] = []
    @State private var measureSeed: String = ""

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(height: estimatedHeight)
    }

    // Derived from cached layout once available.
    private var estimatedHeight: CGFloat {
        let count = max(lines.count, fallbackLineEstimate)
        return CGFloat(count) * lineHeight
    }

    private var fallbackLineEstimate: Int {
        // Quick heuristic: ~50 chars per line at baseSize.
        max(1, Int((Double(text.count) / 50.0).rounded(.up)))
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if lines.isEmpty {
            // First-paint fallback: a single Text with simple inline highlights
            // produced via AttributedString. Once pretext finishes, we swap in
            // the per-line, per-fragment renderer below.
            attributedFallbackView(width: width)
                .task(id: measureKey(width: width)) { await measure(at: width) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(Array(line.fragments.enumerated()), id: \.offset) { _, frag in
                            renderedFragment(frag)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: lineHeight, alignment: .leading)
                    .frame(maxWidth: width, alignment: .leading)
                }
            }
            .frame(maxWidth: width, alignment: .leading)
            .task(id: measureKey(width: width)) { await measure(at: width) }
        }
    }

    @ViewBuilder
    private func renderedFragment(_ fragment: PretextRichFragment) -> some View {
        let run = runs.indices.contains(fragment.itemIndex) ? runs[fragment.itemIndex] : .body(text: fragment.text, size: baseSize)
        switch run.kind {
        case .body:
            Text(fragment.text)
                .font(.system(size: baseSize, weight: .regular, design: .rounded))
                .foregroundStyle(baseColor)
                .padding(.leading, fragment.gapBefore)
        case .mention:
            Text(fragment.text)
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
    }

    @ViewBuilder
    private func attributedFallbackView(width: CGFloat) -> some View {
        Text(buildAttributedFallback())
            .font(.system(size: baseSize, weight: .regular, design: .rounded))
            .foregroundStyle(baseColor)
            .frame(maxWidth: width, alignment: .leading)
            .lineSpacing(max(0, lineHeight - baseSize - 4))
    }

    private func buildAttributedFallback() -> AttributedString {
        let parsedRuns = Self.parseRuns(text, baseSize: baseSize)
        var attr = AttributedString()
        for run in parsedRuns {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .body:
                piece.foregroundColor = baseColor
            case .mention:
                piece.foregroundColor = mentionColor
                piece.font = .system(size: baseSize - 1, weight: .semibold, design: .rounded)
            case .code:
                piece.foregroundColor = codeColor
                piece.font = .system(size: baseSize - 1, weight: .medium, design: .monospaced)
            }
            attr.append(piece)
        }
        return attr
    }

    // MARK: - Measurement

    private func measureKey(width: CGFloat) -> String {
        "\(text.hashValue)|\(baseSize)|\(width)|\(lineHeight)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        let parsedRuns = Self.parseRuns(text, baseSize: baseSize)
        let items = parsedRuns.map { $0.toPretextItem(baseSize: baseSize) }
        do {
            let engine = PretextEngine.shared
            let handle = try await engine.prepareRichInline(items: items)
            let resolved = try await engine.layoutRichInline(handle: handle, maxWidth: width)
            // We don't need the handle past one layout, free it.
            await engine.release(handle: handle)
            await MainActor.run {
                self.runs = parsedRuns
                self.lines = resolved
            }
        } catch {
            // Engine unavailable: stick with the AttributedString fallback.
        }
    }

    // MARK: - Run parsing

    fileprivate enum RunKind: Hashable {
        case body
        case mention
        case code
    }

    fileprivate struct RichRun: Hashable {
        let text: String
        let kind: RunKind
        let size: CGFloat

        static func body(text: String, size: CGFloat) -> RichRun {
            RichRun(text: text, kind: .body, size: size)
        }

        static func mention(text: String, size: CGFloat) -> RichRun {
            RichRun(text: text, kind: .mention, size: size)
        }

        static func code(text: String, size: CGFloat) -> RichRun {
            RichRun(text: text, kind: .code, size: size)
        }

        func toPretextItem(baseSize: CGFloat) -> PretextRichInlineItem {
            switch kind {
            case .body:
                return PretextRichInlineItem(
                    text: text,
                    font: "400 \(Int(baseSize))px -apple-system"
                )
            case .mention:
                return PretextRichInlineItem(
                    text: text,
                    font: "600 \(Int(baseSize - 1))px -apple-system",
                    breakNever: true,
                    extraWidth: 12 // 6pt horizontal padding × 2
                )
            case .code:
                return PretextRichInlineItem(
                    text: text,
                    // Splittable code (let pretext break long inline code).
                    font: "500 \(Int(baseSize - 1))px ui-monospace, Menlo, monospace",
                    extraWidth: 10 // 5pt horizontal padding × 2
                )
            }
        }
    }

    /// Splits the text into typed runs. Detects:
    ///   - `@handle` mentions (alphanum + dot/underscore/dash)
    ///   - `` `inline code` ``
    fileprivate static func parseRuns(_ source: String, baseSize: CGFloat) -> [RichRun] {
        var runs: [RichRun] = []
        var buffer = ""
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            if ch == "`" {
                // Flush body buffer.
                if !buffer.isEmpty { runs.append(.body(text: buffer, size: baseSize)); buffer = "" }
                // Scan to closing backtick on same line.
                var codeBody = ""
                var j = source.index(after: i)
                var closed = false
                while j < source.endIndex {
                    let c = source[j]
                    if c == "`" { closed = true; break }
                    if c == "\n" { break }
                    codeBody.append(c)
                    j = source.index(after: j)
                }
                if closed, !codeBody.isEmpty {
                    runs.append(.code(text: codeBody, size: baseSize))
                    i = source.index(after: j)
                } else {
                    // Unclosed backtick — emit as body text.
                    buffer.append("`")
                    i = source.index(after: i)
                }
                continue
            }
            if ch == "@" {
                let prev = (i == source.startIndex) ? Character(" ") : source[source.index(before: i)]
                if prev.isWhitespace || prev == "(" || prev == "[" || prev == "{" || i == source.startIndex {
                    var handle = "@"
                    var j = source.index(after: i)
                    while j < source.endIndex {
                        let c = source[j]
                        if c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." {
                            handle.append(c)
                            j = source.index(after: j)
                        } else { break }
                    }
                    if handle.count > 1 {
                        if !buffer.isEmpty { runs.append(.body(text: buffer, size: baseSize)); buffer = "" }
                        runs.append(.mention(text: handle, size: baseSize))
                        i = j
                        continue
                    }
                }
            }
            buffer.append(ch)
            i = source.index(after: i)
        }
        if !buffer.isEmpty { runs.append(.body(text: buffer, size: baseSize)) }
        return runs
    }
}

// MARK: - Preview

#Preview {
    PretextRichBubble(
        text: "Hey @maya, can you take a look at the `parseRuns` function? I think pretext's `walkLineRanges` will let us simplify the @hermes layout pass."
    )
    .padding()
    .background(MobileTheme.Colors.surface)
}
