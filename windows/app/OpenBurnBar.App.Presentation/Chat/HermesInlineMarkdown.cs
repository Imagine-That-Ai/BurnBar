using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Hermes Inline Markdown
//
// C# peer of `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesInlineMarkdown.swift`.
//
// Phase 3 of the Hermes message parse. Assistant replies arrive as markdown
// (`**bold**`, `### headings`, `- bullets`) but the run stream from phases 1-2
// treats all of it as literal prose. This pass walks the `.Body` runs and:
//   - splits `**bold**` / `__bold__`, `*italic*` / `_italic_`,
//     `***bold italic***`, and `~~strikethrough~~` spans into styled body runs
//     (markers stripped — presentation chrome, like code-span backticks);
//   - strips `#`-`######` heading markers and styles the heading line bold;
//   - rewrites `-` / `*` / `+` list markers to a `•` glyph.
//
// Concatenating `runs.Select(r => r.Text)` after this pass reproduces the prose
// of the input — markdown markers are dropped by design.

public static class HermesInlineMarkdown
{
    private const int MaxInlineMarkupLineCharacters = 8_192;
    private const int MaxInlineDelimiterCandidatesPerLine = 512;
    private const int MaxInlineNestingDepth = 8;

    /// Expand all `.Body` runs in <paramref name="runs"/> into styled body runs.
    /// Non-body runs pass through untouched and reset line-start tracking.
    public static IReadOnlyList<HermesRichRun> Expand(IReadOnlyList<HermesRichRun> runs)
    {
        var output = new List<HermesRichRun>();
        var atLineStart = true;
        foreach (var run in runs)
        {
            if (run.Kind != HermesRichRunKind.Body || run.Text.Length == 0)
            {
                if (run.Text.Length != 0)
                {
                    atLineStart = run.Text.EndsWith("\n", StringComparison.Ordinal);
                }
                output.Add(run);
                continue;
            }
            output.AddRange(ExpandBody(run.Text, ref atLineStart));
        }
        return output;
    }

    // MARK: - Body expansion

    /// Coalesces adjacent same-style segments so the run stream stays minimal
    /// (one run per style change, not one per character).
    private sealed class Emitter
    {
        private readonly List<(string Text, HermesInlineStyle Style)> _segments = new();

        public void Emit(string text, HermesInlineStyle style)
        {
            if (text.Length == 0)
            {
                return;
            }
            if (_segments.Count > 0 && _segments[^1].Style == style)
            {
                _segments[^1] = (_segments[^1].Text + text, style);
            }
            else
            {
                _segments.Add((text, style));
            }
        }

        public List<HermesRichRun> Runs()
        {
            var runs = new List<HermesRichRun>(_segments.Count);
            foreach (var (text, style) in _segments)
            {
                runs.Add(HermesRichRun.Body(text, style));
            }
            return runs;
        }
    }

    private static List<HermesRichRun> ExpandBody(string source, ref bool atLineStart)
    {
        var emitter = new Emitter();
        var i = 0;
        while (i < source.Length)
        {
            var newline = source.IndexOf('\n', i);
            var lineEnd = newline < 0 ? source.Length : newline;
            var lineStart = i;
            var lineLen = lineEnd - lineStart;
            var lineStyle = HermesInlineStyle.None;
            if (atLineStart)
            {
                (lineStart, lineLen, lineStyle) = StripBlockMarkers(source, lineStart, lineLen, emitter);
            }
            ScanInline(source, lineStart, lineLen, lineStyle, depth: 0, emitter);
            if (lineEnd < source.Length)
            {
                emitter.Emit("\n", HermesInlineStyle.None);
                i = lineEnd + 1;
                atLineStart = true;
            }
            else
            {
                i = lineEnd;
                atLineStart = false;
            }
        }
        return emitter.Runs();
    }

    // MARK: - Block markers (line start only)

    /// Strip heading / bullet markers from the head of the line span. Returns
    /// the remaining (start, length) plus the style the whole line inherits
    /// (headings render bold). Bullet indent + `•` is emitted directly.
    private static (int Start, int Length, HermesInlineStyle Style) StripBlockMarkers(
        string source, int start, int length, Emitter emitter)
    {
        var end = start + length;

        // Heading: `#{1,6}` + space -> bold line, markers dropped.
        var idx = start;
        var hashes = 0;
        while (idx < end && source[idx] == '#')
        {
            hashes++;
            idx++;
        }
        if (hashes >= 1 && hashes <= 6 && idx < end && source[idx] == ' ')
        {
            while (idx < end && source[idx] == ' ')
            {
                idx++;
            }
            return (idx, end - idx, HermesInlineStyle.Bold);
        }

        // Bullet: optional indent, `-` / `*` / `+`, then a space -> `• `.
        var ws = start;
        while (ws < end && (source[ws] == ' ' || source[ws] == '\t'))
        {
            ws++;
        }
        if (ws < end && (source[ws] == '-' || source[ws] == '*' || source[ws] == '+'))
        {
            var afterMarker = ws + 1;
            if (afterMarker < end && source[afterMarker] == ' ')
            {
                emitter.Emit(source.Substring(start, ws - start) + "• ", HermesInlineStyle.None);
                var content = afterMarker;
                while (content < end && source[content] == ' ')
                {
                    content++;
                }
                return (content, end - content, HermesInlineStyle.None);
            }
        }

        return (start, length, HermesInlineStyle.None);
    }

    // MARK: - Inline emphasis

    /// Scan one line span (or one emphasis span's content — recursion handles
    /// `**bold with *nested italics***`) and emit styled segments.
    private static void ScanInline(
        string source, int start, int length, HermesInlineStyle baseStyle, int depth, Emitter emitter)
    {
        var end = start + length;
        if (depth >= MaxInlineNestingDepth || !ShouldScanInlineMarkup(source, start, length))
        {
            emitter.Emit(source.Substring(start, length), baseStyle);
            return;
        }

        var plain = new System.Text.StringBuilder();
        var i = start;
        while (i < end)
        {
            var ch = source[i];
            if (ch == '*' || ch == '_' || ch == '~')
            {
                var previous = plain.Length > 0 ? plain[^1] : (char?)null;
                var span = MatchSpan(source, i, end, ch, previous);
                if (span is { } s)
                {
                    emitter.Emit(plain.ToString(), baseStyle);
                    plain.Clear();
                    ScanInline(source, s.ContentStart, s.ContentEnd - s.ContentStart,
                        baseStyle | s.Style, depth + 1, emitter);
                    i = s.End;
                    continue;
                }
            }
            plain.Append(ch);
            i++;
        }
        emitter.Emit(plain.ToString(), baseStyle);
    }

    private static bool ShouldScanInlineMarkup(string source, int start, int length)
    {
        var characters = 0;
        var candidates = 0;
        var end = start + length;
        for (var i = start; i < end; i++)
        {
            characters++;
            if (characters > MaxInlineMarkupLineCharacters)
            {
                return false;
            }
            var ch = source[i];
            if (ch == '*' || ch == '_' || ch == '~')
            {
                candidates++;
                if (candidates > MaxInlineDelimiterCandidatesPerLine)
                {
                    return false;
                }
            }
        }
        return true;
    }

    private readonly record struct Span(int ContentStart, int ContentEnd, HermesInlineStyle Style, int End);

    /// Match a delimited emphasis span starting at <paramref name="start"/> (the
    /// first delimiter char). <paramref name="previous"/> is the character before
    /// the delimiter run (null at a segment boundary) — `_` requires a word
    /// boundary there so `snake_case_names` stay literal.
    private static Span? MatchSpan(string source, int start, int end, char delimiter, char? previous)
    {
        // Measure the opening delimiter run.
        var contentStart = start;
        var length = 0;
        while (contentStart < end && source[contentStart] == delimiter)
        {
            length++;
            contentStart++;
        }

        HermesInlineStyle style;
        switch ((delimiter, length))
        {
            case ('~', 2):
                style = HermesInlineStyle.Strikethrough;
                break;
            case ('*', 1):
            case ('_', 1):
                style = HermesInlineStyle.Italic;
                break;
            case ('*', 2):
            case ('_', 2):
                style = HermesInlineStyle.Bold;
                break;
            case ('*', 3):
            case ('_', 3):
                style = HermesInlineStyle.Bold | HermesInlineStyle.Italic;
                break;
            default:
                return null;
        }

        // Opener: must be followed by non-whitespace.
        if (contentStart >= end || char.IsWhiteSpace(source[contentStart]))
        {
            return null;
        }
        // `_` opener additionally needs a word boundary on the left.
        if (delimiter == '_' && previous is { } prev && (char.IsLetter(prev) || char.IsNumber(prev)))
        {
            return null;
        }

        // Find the closing run: same delimiter, run of at least `length`,
        // preceded by non-whitespace, non-empty content.
        var j = contentStart;
        while (j < end)
        {
            if (source[j] != delimiter)
            {
                j++;
                continue;
            }
            var runEnd = j;
            var runLength = 0;
            while (runEnd < end && source[runEnd] == delimiter)
            {
                runLength++;
                runEnd++;
            }
            if (runLength >= length && j > contentStart && !char.IsWhiteSpace(source[j - 1]))
            {
                // `_` closer needs a word boundary on the right.
                var closerEnd = j + length;
                if (delimiter == '_' && closerEnd < end
                    && (char.IsLetter(source[closerEnd]) || char.IsNumber(source[closerEnd])))
                {
                    j = runEnd;
                    continue;
                }
                return new Span(contentStart, j, style, closerEnd);
            }
            j = runEnd;
        }
        return null;
    }
}
