import Foundation

// MARK: - Hermes Rich Run
//
// One typed segment of a parsed Hermes message. Runs preserve the original
// reading order; rendering always concatenates them in sequence.

public enum HermesRichRunKind: Hashable, Sendable {
    case body
    case atom(HermesAtom, label: String)
    /// `@handle` mention. Atomic, accent-colored chip in the bubble.
    case mention(handle: String)
    /// `` `inline code` ``. Splittable mono span.
    case code
}

public struct HermesRichRun: Hashable, Sendable {
    public let text: String
    public let kind: HermesRichRunKind

    public init(text: String, kind: HermesRichRunKind) {
        self.text = text
        self.kind = kind
    }

    public static func body(_ text: String) -> HermesRichRun {
        HermesRichRun(text: text, kind: .body)
    }

    public static func atom(_ atom: HermesAtom, label: String) -> HermesRichRun {
        HermesRichRun(text: label, kind: .atom(atom, label: label))
    }

    public static func mention(_ handle: String) -> HermesRichRun {
        HermesRichRun(text: handle, kind: .mention(handle: handle))
    }

    public static func code(_ text: String) -> HermesRichRun {
        HermesRichRun(text: text, kind: .code)
    }

    public var isAtomic: Bool {
        switch kind {
        case .atom, .mention: return true
        case .body, .code:    return false
        }
    }

    public var atom: HermesAtom? {
        if case let .atom(atom, _) = kind { return atom }
        return nil
    }
}

// MARK: - Hermes Atom Parser
//
// Two-pass parser. Pass 1 extracts canonical `[label](burnbar://...)`
// markdown links emitted by Hermes (or hand-authored). Pass 2 walks the
// remaining body text and finds entities Hermes emitted in plain prose
// using deterministic regex patterns:
//
//   - `@handle` mentions
//   - `` `inline code` ``
//   - `$1.23` / `$1,234.56` cost atoms (defaulting window=`.today`)
//   - Known model IDs from a small dictionary of canonical OpenBurnBar
//     model identifiers
//
// All output preserves source-text order and full character coverage —
// concatenating `runs.map(\.text)` always reproduces the input within
// link-flattening semantics (link text is preserved as the chip label).

public enum HermesAtomParser {

    /// Parse `text` into a stream of `HermesRichRun`s. Cross-platform —
    /// no SwiftUI / UIKit / AppKit imports.
    public static func parse(_ text: String) -> [HermesRichRun] {
        // Phase 1: extract markdown links and split into alternating
        // (body, link) regions.
        let withLinks = extractMarkdownLinks(in: text)

        // Phase 2: for each body region, run the entity sub-parser.
        var output: [HermesRichRun] = []
        for chunk in withLinks {
            switch chunk {
            case .link(let atom, let label):
                output.append(.atom(atom, label: label))
            case .text(let body):
                output.append(contentsOf: parseEntities(in: body))
            }
        }
        return output
    }

    // MARK: - Phase 1: markdown link extraction

    private enum LinkChunk {
        case text(String)
        case link(HermesAtom, label: String)
    }

    /// Scan for `[label](burnbar://...)` patterns and split the text into
    /// alternating body/link chunks.
    private static func extractMarkdownLinks(in source: String) -> [LinkChunk] {
        var output: [LinkChunk] = []
        var bodyStart = source.startIndex
        var i = source.startIndex
        while i < source.endIndex {
            // Look for an opening `[`. We respect a single backslash escape:
            // `\[` is treated as literal text.
            if source[i] == "[" {
                let escaped = (i > source.startIndex) && source[source.index(before: i)] == "\\"
                if !escaped, let match = matchMarkdownLink(in: source, startingAt: i) {
                    if bodyStart < i {
                        output.append(.text(String(source[bodyStart..<i])))
                    }
                    output.append(.link(match.atom, label: match.label))
                    i = match.endIndex
                    bodyStart = i
                    continue
                }
            }
            i = source.index(after: i)
        }
        if bodyStart < source.endIndex {
            output.append(.text(String(source[bodyStart..<source.endIndex])))
        }
        return output
    }

    private struct MarkdownLinkMatch {
        let atom: HermesAtom
        let label: String
        let endIndex: String.Index
    }

    /// Match a single `[label](burnbar://...)` starting at `start` (the `[`).
    /// Returns `nil` if the construct doesn't form a complete burnbar atom.
    private static func matchMarkdownLink(
        in source: String,
        startingAt start: String.Index
    ) -> MarkdownLinkMatch? {
        // 1. Find the closing `]`.
        var idx = source.index(after: start)
        var label = ""
        var depth = 1
        while idx < source.endIndex {
            let c = source[idx]
            if c == "\n" { return nil }       // labels don't span lines
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            label.append(c)
            idx = source.index(after: idx)
        }
        guard idx < source.endIndex, source[idx] == "]" else { return nil }
        // 2. Require an immediate `(` after the `]`.
        let afterCloseBracket = source.index(after: idx)
        guard afterCloseBracket < source.endIndex, source[afterCloseBracket] == "(" else { return nil }
        // 3. Read the URL up to `)`.
        var urlIdx = source.index(after: afterCloseBracket)
        var urlString = ""
        while urlIdx < source.endIndex {
            let c = source[urlIdx]
            if c == ")" { break }
            if c == "\n" { return nil }
            urlString.append(c)
            urlIdx = source.index(after: urlIdx)
        }
        guard urlIdx < source.endIndex, source[urlIdx] == ")" else { return nil }
        let endIndex = source.index(after: urlIdx)
        // 4. Must decode to a real atom.
        guard let atom = HermesAtomURL.decode(urlString) else { return nil }
        let cleanedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = cleanedLabel.isEmpty ? atom.fallbackLabel : cleanedLabel
        return MarkdownLinkMatch(atom: atom, label: resolvedLabel, endIndex: endIndex)
    }

    // MARK: - Phase 2: entity regex fallback

    /// Parse a span of free text (no markdown links) into runs by detecting
    /// `@mentions`, `` `code` ``, `$cost` patterns, and known model IDs.
    private static func parseEntities(in source: String) -> [HermesRichRun] {
        var output: [HermesRichRun] = []
        var buffer = ""
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            // Backtick code span.
            if ch == "`" {
                if !buffer.isEmpty {
                    output.append(contentsOf: scanForRegexAtoms(in: buffer))
                    buffer = ""
                }
                if let match = matchInlineCode(in: source, startingAt: i) {
                    output.append(.code(match.body))
                    i = match.endIndex
                    continue
                } else {
                    buffer.append("`")
                    i = source.index(after: i)
                    continue
                }
            }
            // Mention.
            if ch == "@" {
                let prev = (i == source.startIndex) ? Character(" ") : source[source.index(before: i)]
                if prev.isWhitespace || prev == "(" || prev == "[" || prev == "{" {
                    if let match = matchMention(in: source, startingAt: i) {
                        if !buffer.isEmpty {
                            output.append(contentsOf: scanForRegexAtoms(in: buffer))
                            buffer = ""
                        }
                        output.append(.mention(match.handle))
                        i = match.endIndex
                        continue
                    }
                }
            }
            buffer.append(ch)
            i = source.index(after: i)
        }
        if !buffer.isEmpty {
            output.append(contentsOf: scanForRegexAtoms(in: buffer))
        }
        return output
    }

    private struct InlineCodeMatch {
        let body: String
        let endIndex: String.Index
    }

    private static func matchInlineCode(
        in source: String,
        startingAt start: String.Index
    ) -> InlineCodeMatch? {
        var idx = source.index(after: start)
        var body = ""
        while idx < source.endIndex {
            let c = source[idx]
            if c == "`" {
                guard !body.isEmpty else { return nil }
                return InlineCodeMatch(body: body, endIndex: source.index(after: idx))
            }
            if c == "\n" { return nil }
            body.append(c)
            idx = source.index(after: idx)
        }
        return nil
    }

    private struct MentionMatch {
        let handle: String
        let endIndex: String.Index
    }

    private static func matchMention(
        in source: String,
        startingAt start: String.Index
    ) -> MentionMatch? {
        var idx = source.index(after: start)
        var handle = "@"
        while idx < source.endIndex {
            let c = source[idx]
            if c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." {
                handle.append(c)
                idx = source.index(after: idx)
            } else {
                break
            }
        }
        guard handle.count > 1 else { return nil }
        return MentionMatch(handle: handle, endIndex: idx)
    }

    /// Free-text body inside the entity parser. Walks once with a regex that
    /// matches `$cost` or known model IDs and splits accordingly. We use
    /// `NSRegularExpression` for stability across iOS/macOS and call sites.
    private static func scanForRegexAtoms(in source: String) -> [HermesRichRun] {
        guard !source.isEmpty else { return [] }

        // Build a unioned pattern. Order of alternation matters — costs come
        // first so `$2.34` doesn't get fragmented.
        // Costs: $123, $1,234, $1,234.56, $1.23. Allow optional comma groups.
        // Models: small allowlist of canonical IDs.
        let modelAlternation = knownModelIDs.joined(separator: "|")
        let pattern = #"(\$\d{1,3}(?:,\d{3})*(?:\.\d+)?)|("# + modelAlternation + #")"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.useUnicodeWordBoundaries]) else {
            return [.body(source)]
        }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let matches = regex.matches(in: source, options: [], range: fullRange)
        if matches.isEmpty {
            return [.body(source)]
        }

        var output: [HermesRichRun] = []
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                let prefixRange = NSRange(location: cursor, length: range.location - cursor)
                output.append(.body(nsSource.substring(with: prefixRange)))
            }
            let matched = nsSource.substring(with: range)

            if let cost = parseCost(from: matched) {
                output.append(.atom(.cost(amount: cost, window: .today), label: matched))
            } else if knownModelIDs.contains(matched) {
                output.append(.atom(.model(id: matched), label: matched))
            } else {
                output.append(.body(matched))
            }
            cursor = range.location + range.length
        }
        if cursor < nsSource.length {
            output.append(.body(nsSource.substring(with: NSRange(location: cursor, length: nsSource.length - cursor))))
        }
        return output
    }

    private static func parseCost(from matched: String) -> Double? {
        guard matched.hasPrefix("$") else { return nil }
        let trimmed = matched.dropFirst().replacingOccurrences(of: ",", with: "")
        return Double(trimmed)
    }

    /// Allowlist of canonical model identifiers. We keep this minimal +
    /// deterministic — only IDs the app actually surfaces. Hermes is the
    /// authoritative source for newer models via markdown-link emission.
    private static let knownModelIDs: [String] = [
        "claude-sonnet-4.7",
        "claude-sonnet-4.6",
        "claude-sonnet-4.5",
        "claude-opus-4.7",
        "claude-opus-4.6",
        "claude-haiku-4.7",
        "gpt-5.5",
        "gpt-5",
        "gpt-4.6",
        "gpt-4o",
        "gpt-4o-mini",
        "o1-preview",
        "o1-mini",
        "minimax-m2.7",
        "minimax-m2",
        "kimi-k1.7",
        "kimi-k1.5",
        "glm-5",
        "glm-4.6",
        "deepseek-v3.5",
        "gemini-3-pro",
        "gemini-3-flash"
    ]
}
