import Foundation

// MARK: - Hermes Inline Style
//
// Inline-markdown styling carried by a `.body` run. Styles combine like an
// OptionSet so a heading line (bold) containing `*emphasis*` unions to
// `[.bold, .italic]`.

public struct HermesInlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold          = HermesInlineStyle(rawValue: 1 << 0)
    public static let italic        = HermesInlineStyle(rawValue: 1 << 1)
    public static let strikethrough = HermesInlineStyle(rawValue: 1 << 2)
}

// MARK: - Hermes Inline Markdown
//
// Phase 3 of the Hermes message parse. Assistant replies arrive as markdown
// (`**bold**`, `### headings`, `- bullets`) but the run stream from phases
// 1–2 treats all of it as literal prose — which is exactly why replies used
// to show `**Hello!**` with raw asterisks. This pass walks the `.body` runs
// and:
//
//   - splits `**bold**` / `__bold__`, `*italic*` / `_italic_`,
//     `***bold italic***`, and `~~strikethrough~~` spans into styled body
//     runs (markers stripped — they are presentation chrome, exactly like
//     code-span backticks);
//   - strips `#`–`######` heading markers and styles the heading line bold;
//   - rewrites `-` / `*` / `+` list markers to a `•` glyph.
//
// Like phase 1's link flattening, concatenating `runs.map(\.text)` after
// this pass reproduces the *prose* of the input — markdown markers are
// dropped by design.
//
// Known, accepted limits (all rare in real Hermes output): emphasis spans
// never cross an atom / mention / code boundary (`**$2.34**` keeps its
// asterisks because the cost atom split the body run first), spans never
// cross lines, and unmatched markers stay literal.

public enum HermesInlineMarkdown {

    // MARK: Run-stream expansion

    /// Expand all `.body` runs in `runs` into styled body runs. Non-body
    /// runs pass through untouched and reset line-start tracking (chips,
    /// mentions, and code spans never contain newlines, so after one we are
    /// mid-line by definition).
    public static func expand(_ runs: [HermesRichRun]) -> [HermesRichRun] {
        var output: [HermesRichRun] = []
        var atLineStart = true
        for run in runs {
            guard case .body = run.kind, !run.text.isEmpty else {
                if !run.text.isEmpty {
                    atLineStart = run.text.hasSuffix("\n")
                }
                output.append(run)
                continue
            }
            output.append(contentsOf: expandBody(run.text, atLineStart: &atLineStart))
        }
        return output
    }

    /// Render `text` (a full Hermes/agent message) into an `AttributedString`
    /// using Foundation presentation intents only — no fonts, no colors, no
    /// platform UI imports. SwiftUI `Text` resolves the intents against the
    /// ambient font, so call sites keep full control of typography. Atom and
    /// mention labels render strongly emphasized; code spans render with the
    /// `.code` intent (monospaced).
    ///
    /// This is the lightweight sibling of the chip-rendering rich bubbles —
    /// right for cards, banners, and any surface where tappable atom chips
    /// would be overkill but raw markdown markers would be wrong.
    public static func attributedString(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in HermesAtomParser.parse(text) {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .body(let style):
                var intent: InlinePresentationIntent = []
                if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if style.contains(.italic) { intent.insert(.emphasized) }
                if style.contains(.strikethrough) { intent.insert(.strikethrough) }
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            case .atom, .mention:
                piece.inlinePresentationIntent = .stronglyEmphasized
            case .code:
                piece.inlinePresentationIntent = .code
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Body expansion

    /// Coalesces adjacent same-style segments so the run stream stays
    /// minimal (one run per style change, not one per character).
    private struct Emitter {
        var segments: [(text: String, style: HermesInlineStyle)] = []

        mutating func emit(_ text: some StringProtocol, _ style: HermesInlineStyle) {
            guard !text.isEmpty else { return }
            if let last = segments.indices.last, segments[last].style == style {
                segments[last].text += text
            } else {
                segments.append((String(text), style))
            }
        }

        var runs: [HermesRichRun] {
            segments.map { .body($0.text, style: $0.style) }
        }
    }

    /// Expand one `.body` run. `atLineStart` is cross-run state owned by
    /// `expand` — true when the previous character in the whole message was
    /// a newline (or the message just started).
    private static func expandBody(_ source: String, atLineStart: inout Bool) -> [HermesRichRun] {
        var emitter = Emitter()
        var i = source.startIndex
        while i < source.endIndex {
            let lineEnd = source[i...].firstIndex(of: "\n") ?? source.endIndex
            var line = source[i..<lineEnd]
            var lineStyle: HermesInlineStyle = []
            if atLineStart {
                (line, lineStyle) = stripBlockMarkers(line, into: &emitter)
            }
            scanInline(line, baseStyle: lineStyle, into: &emitter)
            if lineEnd < source.endIndex {
                emitter.emit("\n", [])
                i = source.index(after: lineEnd)
                atLineStart = true
            } else {
                i = lineEnd
                atLineStart = false
            }
        }
        return emitter.runs
    }

    // MARK: - Block markers (line start only)

    /// Strip heading / bullet markers from the head of `line`. Returns the
    /// remaining line content plus the style the whole line inherits
    /// (headings render bold). Bullet indent + `•` is emitted directly.
    private static func stripBlockMarkers(
        _ line: Substring,
        into emitter: inout Emitter
    ) -> (Substring, HermesInlineStyle) {
        // Heading: `#{1,6}` + space → bold line, markers dropped.
        var idx = line.startIndex
        var hashes = 0
        while idx < line.endIndex, line[idx] == "#" {
            hashes += 1
            idx = line.index(after: idx)
        }
        if (1...6).contains(hashes), idx < line.endIndex, line[idx] == " " {
            let content = line[idx...].drop(while: { $0 == " " })
            return (content, .bold)
        }

        // Bullet: optional indent, `-` / `*` / `+`, then a space → `• `.
        // The space requirement disambiguates from emphasis (`*italic*`)
        // and horizontal rules (`---`).
        var ws = line.startIndex
        while ws < line.endIndex, line[ws] == " " || line[ws] == "\t" {
            ws = line.index(after: ws)
        }
        if ws < line.endIndex,
           line[ws] == "-" || line[ws] == "*" || line[ws] == "+" {
            let afterMarker = line.index(after: ws)
            if afterMarker < line.endIndex, line[afterMarker] == " " {
                emitter.emit(line[line.startIndex..<ws] + "• ", [])
                let content = line[afterMarker...].drop(while: { $0 == " " })
                return (content, [])
            }
        }

        return (line, [])
    }

    // MARK: - Inline emphasis

    /// Scan one line (or one emphasis span's content — the recursion handles
    /// `**bold with *nested italics***`) and emit styled segments.
    private static func scanInline(
        _ source: Substring,
        baseStyle: HermesInlineStyle,
        into emitter: inout Emitter
    ) {
        var plain = ""
        var i = source.startIndex

        while i < source.endIndex {
            let ch = source[i]
            if ch == "*" || ch == "_" || ch == "~",
               let span = matchSpan(source, at: i, delimiter: ch, previous: plain.last) {
                emitter.emit(plain, baseStyle)
                plain = ""
                scanInline(span.content, baseStyle: baseStyle.union(span.style), into: &emitter)
                i = span.end
                continue
            }
            plain.append(ch)
            i = source.index(after: i)
        }
        emitter.emit(plain, baseStyle)
    }

    private struct Span {
        let content: Substring
        let style: HermesInlineStyle
        let end: Substring.Index
    }

    /// Match a delimited emphasis span starting at `start` (the first
    /// delimiter character). `previous` is the character immediately before
    /// the delimiter run (nil at a segment boundary) — `_` requires a word
    /// boundary there so `snake_case_names` stay literal.
    private static func matchSpan(
        _ source: Substring,
        at start: Substring.Index,
        delimiter: Character,
        previous: Character?
    ) -> Span? {
        // Measure the opening delimiter run.
        var contentStart = start
        var length = 0
        while contentStart < source.endIndex, source[contentStart] == delimiter {
            length += 1
            contentStart = source.index(after: contentStart)
        }

        let style: HermesInlineStyle
        switch (delimiter, length) {
        case ("~", 2):        style = .strikethrough
        case ("*", 1), ("_", 1): style = .italic
        case ("*", 2), ("_", 2): style = .bold
        case ("*", 3), ("_", 3): style = [.bold, .italic]
        default:              return nil
        }

        // Opener: must be followed by non-whitespace.
        guard contentStart < source.endIndex, !source[contentStart].isWhitespace else {
            return nil
        }
        // `_` opener additionally needs a word boundary on the left.
        if delimiter == "_", let previous, previous.isLetter || previous.isNumber {
            return nil
        }

        // Find the closing run: same delimiter, run of at least `length`,
        // preceded by non-whitespace, non-empty content.
        var j = contentStart
        while j < source.endIndex {
            guard source[j] == delimiter else {
                j = source.index(after: j)
                continue
            }
            var runEnd = j
            var runLength = 0
            while runEnd < source.endIndex, source[runEnd] == delimiter {
                runLength += 1
                runEnd = source.index(after: runEnd)
            }
            if runLength >= length,
               j > contentStart,
               !source[source.index(before: j)].isWhitespace {
                // `_` closer needs a word boundary on the right.
                let closerEnd = source.index(j, offsetBy: length)
                if delimiter == "_",
                   closerEnd < source.endIndex,
                   source[closerEnd].isLetter || source[closerEnd].isNumber {
                    j = runEnd
                    continue
                }
                return Span(
                    content: source[contentStart..<j],
                    style: style,
                    end: closerEnd
                )
            }
            j = runEnd
        }
        return nil
    }
}
