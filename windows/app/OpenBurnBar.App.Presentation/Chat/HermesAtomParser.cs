using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Hermes Atom Parser
//
// C# peer of `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomParser.swift`.
//
// Three-pass parser:
//   Pass 1 extracts canonical `[label](burnbar://...)` markdown links.
//   Pass 2 walks the remaining prose for entities Hermes emits in plain text:
//     `@handle` mentions, `` `inline code` ``, `$1.23` cost atoms, and known
//     model IDs from a small allowlist.
//   Pass 3 (`HermesInlineMarkdown.Expand`) resolves inline markdown emphasis.
//
// All output preserves source-text order and full *prose* coverage —
// concatenating `runs.Select(r => r.Text)` reproduces the input within
// marker-flattening semantics (link text kept as chip label; code-span
// backticks, emphasis markers, and heading hashes dropped as chrome; list
// markers rendered as `•`). Fully cross-platform — no WinUI dependency.

public static class HermesAtomParser
{
    /// Parse <paramref name="text"/> into a stream of <see cref="HermesRichRun"/>s.
    public static IReadOnlyList<HermesRichRun> Parse(string text)
    {
        // Phase 1: extract markdown links, split into (body, link) regions.
        var withLinks = ExtractMarkdownLinks(text);

        // Phase 2: run the entity sub-parser on each body region.
        var output = new List<HermesRichRun>();
        foreach (var chunk in withLinks)
        {
            if (chunk.Atom is { } atom)
            {
                output.Add(HermesRichRun.MakeAtom(atom, chunk.Text));
            }
            else
            {
                output.AddRange(ParseEntities(chunk.Text));
            }
        }

        // Phase 3: resolve inline markdown emphasis into styled body runs.
        return HermesInlineMarkdown.Expand(output);
    }

    /// Flatten <paramref name="text"/> to plain prose for surfaces that cannot
    /// render runs (notification bodies, previews). Markers stripped, labels kept.
    public static string PlainText(string text)
    {
        var builder = new StringBuilder();
        foreach (var run in Parse(text))
        {
            builder.Append(run.Text);
        }
        return builder.ToString();
    }

    // MARK: - Phase 1: markdown link extraction

    private readonly record struct LinkChunk(string Text, HermesAtom? Atom);

    private static List<LinkChunk> ExtractMarkdownLinks(string source)
    {
        var output = new List<LinkChunk>();
        var bodyStart = 0;
        var i = 0;
        while (i < source.Length)
        {
            if (source[i] == '[')
            {
                var escaped = i > 0 && source[i - 1] == '\\';
                if (!escaped)
                {
                    var match = MatchMarkdownLink(source, i);
                    if (match is { } m)
                    {
                        if (bodyStart < i)
                        {
                            output.Add(new LinkChunk(source.Substring(bodyStart, i - bodyStart), null));
                        }
                        output.Add(new LinkChunk(m.Label, m.Atom));
                        i = m.EndIndex;
                        bodyStart = i;
                        continue;
                    }
                }
            }
            i++;
        }
        if (bodyStart < source.Length)
        {
            output.Add(new LinkChunk(source.Substring(bodyStart), null));
        }
        return output;
    }

    private readonly record struct MarkdownLinkMatch(HermesAtom Atom, string Label, int EndIndex);

    /// Match a single `[label](burnbar://...)` starting at <paramref name="start"/>
    /// (the `[`). Returns null if the construct doesn't form a complete burnbar atom.
    private static MarkdownLinkMatch? MatchMarkdownLink(string source, int start)
    {
        // 1. Find the closing `]` (respecting nested brackets).
        var idx = start + 1;
        var label = new StringBuilder();
        var depth = 1;
        while (idx < source.Length)
        {
            var c = source[idx];
            if (c == '\n')
            {
                return null; // labels don't span lines
            }
            if (c == '[')
            {
                depth++;
            }
            if (c == ']')
            {
                depth--;
                if (depth == 0)
                {
                    break;
                }
            }
            label.Append(c);
            idx++;
        }
        if (idx >= source.Length || source[idx] != ']')
        {
            return null;
        }
        // 2. Require an immediate `(` after the `]`.
        var afterClose = idx + 1;
        if (afterClose >= source.Length || source[afterClose] != '(')
        {
            return null;
        }
        // 3. Read the URL up to `)`.
        var urlIdx = afterClose + 1;
        var urlString = new StringBuilder();
        while (urlIdx < source.Length)
        {
            var c = source[urlIdx];
            if (c == ')')
            {
                break;
            }
            if (c == '\n')
            {
                return null;
            }
            urlString.Append(c);
            urlIdx++;
        }
        if (urlIdx >= source.Length || source[urlIdx] != ')')
        {
            return null;
        }
        var endIndex = urlIdx + 1;
        // 4. Must decode to a real atom.
        var atom = HermesAtomUrl.Decode(urlString.ToString());
        if (atom is null)
        {
            return null;
        }
        var cleanedLabel = label.ToString().Trim();
        var resolvedLabel = cleanedLabel.Length == 0 ? atom.FallbackLabel : cleanedLabel;
        return new MarkdownLinkMatch(atom, resolvedLabel, endIndex);
    }

    // MARK: - Phase 2: entity regex fallback

    private static List<HermesRichRun> ParseEntities(string source)
    {
        var output = new List<HermesRichRun>();
        var buffer = new StringBuilder();
        var i = 0;
        while (i < source.Length)
        {
            var ch = source[i];

            // Backtick code span.
            if (ch == '`')
            {
                if (buffer.Length > 0)
                {
                    output.AddRange(ScanForRegexAtoms(buffer.ToString()));
                    buffer.Clear();
                }
                var code = MatchInlineCode(source, i);
                if (code is { } match)
                {
                    output.Add(HermesRichRun.Code(match.Body));
                    i = match.EndIndex;
                    continue;
                }
                buffer.Append('`');
                i++;
                continue;
            }

            // Mention.
            if (ch == '@')
            {
                var prev = i == 0 ? ' ' : source[i - 1];
                if (char.IsWhiteSpace(prev) || prev == '(' || prev == '[' || prev == '{')
                {
                    var mention = MatchMention(source, i);
                    if (mention is { } m)
                    {
                        if (buffer.Length > 0)
                        {
                            output.AddRange(ScanForRegexAtoms(buffer.ToString()));
                            buffer.Clear();
                        }
                        output.Add(HermesRichRun.Mention(m.Handle));
                        i = m.EndIndex;
                        continue;
                    }
                }
            }

            buffer.Append(ch);
            i++;
        }
        if (buffer.Length > 0)
        {
            output.AddRange(ScanForRegexAtoms(buffer.ToString()));
        }
        return output;
    }

    private readonly record struct InlineCodeMatch(string Body, int EndIndex);

    private static InlineCodeMatch? MatchInlineCode(string source, int start)
    {
        var idx = start + 1;
        var body = new StringBuilder();
        while (idx < source.Length)
        {
            var c = source[idx];
            if (c == '`')
            {
                if (body.Length == 0)
                {
                    return null;
                }
                return new InlineCodeMatch(body.ToString(), idx + 1);
            }
            if (c == '\n')
            {
                return null;
            }
            body.Append(c);
            idx++;
        }
        return null;
    }

    private readonly record struct MentionMatch(string Handle, int EndIndex);

    private static MentionMatch? MatchMention(string source, int start)
    {
        var idx = start + 1;
        var handle = new StringBuilder("@");
        while (idx < source.Length)
        {
            var c = source[idx];
            if (char.IsLetter(c) || char.IsNumber(c) || c == '_' || c == '-' || c == '.')
            {
                handle.Append(c);
                idx++;
            }
            else
            {
                break;
            }
        }
        if (handle.Length <= 1)
        {
            return null;
        }
        return new MentionMatch(handle.ToString(), idx);
    }

    private static List<HermesRichRun> ScanForRegexAtoms(string source)
    {
        if (source.Length == 0)
        {
            return new List<HermesRichRun>();
        }

        var matches = EntityRegex.Value.Matches(source);
        if (matches.Count == 0)
        {
            return new List<HermesRichRun> { HermesRichRun.Body(source) };
        }

        var output = new List<HermesRichRun>();
        var cursor = 0;
        foreach (Match match in matches)
        {
            if (match.Index > cursor)
            {
                output.Add(HermesRichRun.Body(source.Substring(cursor, match.Index - cursor)));
            }
            var matched = match.Value;

            var cost = ParseCost(matched);
            if (cost is { } amount)
            {
                output.Add(HermesRichRun.MakeAtom(new HermesAtom.Cost(amount, HermesAtomWindow.Today), matched));
            }
            else if (KnownModelIdSet.Contains(matched))
            {
                output.Add(HermesRichRun.MakeAtom(new HermesAtom.Model(matched), matched));
            }
            else
            {
                output.Add(HermesRichRun.Body(matched));
            }
            cursor = match.Index + match.Length;
        }
        if (cursor < source.Length)
        {
            output.Add(HermesRichRun.Body(source.Substring(cursor)));
        }
        return output;
    }

    private static double? ParseCost(string matched)
    {
        if (!matched.StartsWith("$", StringComparison.Ordinal))
        {
            return null;
        }
        var trimmed = matched.Substring(1).Replace(",", string.Empty);
        return double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? value : null;
    }

    /// Allowlist of canonical model identifiers (byte-for-byte with the Swift
    /// `knownModelIDs`). Kept minimal + deterministic — Hermes is authoritative
    /// for newer models via markdown-link emission.
    private static readonly string[] KnownModelIds =
    {
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
        "gemini-3-flash",
    };

    private static readonly HashSet<string> KnownModelIdSet = new(KnownModelIds, StringComparer.Ordinal);

    // Costs: $123, $1,234, $1,234.56, $1.23. Models: allowlist of canonical IDs.
    // NOTE: the model IDs are joined UNESCAPED — a byte-for-byte port of the Swift
    // pattern, which likewise does not escape the `.` in ids like `gpt-4.6`. The
    // longer alternatives precede the shorter so `gpt-5.5` wins over `gpt-5`.
    // Lazy so it initializes after KnownModelIds regardless of field order.
    private static readonly System.Lazy<Regex> EntityRegex = new(BuildEntityRegex);

    private static Regex BuildEntityRegex()
    {
        var modelAlternation = string.Join("|", KnownModelIds);
        var pattern = @"(\$\d{1,3}(?:,\d{3})*(?:\.\d+)?)|(" + modelAlternation + ")";
        return new Regex(pattern, RegexOptions.CultureInvariant);
    }
}
