using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Presentation.SessionLogs;

// PORTED (faithful, line-for-line) from AgentLens/Services/TranscriptBlockParser.swift.
//
// Parses raw session transcript text (Claude Code, Codex, etc.) into structured
// blocks for the beautified detail transcript. Pure string logic, no dependencies —
// asserted for parity by a real `dotnet test` on macOS (TranscriptBlockParserTests).

/// <summary>Kind of a parsed transcript block. Swift: <c>TranscriptBlock.Kind</c>.</summary>
public enum TranscriptBlockKind
{
    UserMessage,
    AssistantMessage,
    ToolUse,
    CodeBlock,
    Separator,
}

/// <summary>A parsed block from a raw session transcript. Swift: <c>struct TranscriptBlock</c>.</summary>
public sealed class TranscriptBlock(TranscriptBlockKind Kind, string Content, string? Label)
{
    public TranscriptBlockKind Kind { get; set; } = Kind;
    public string Content { get; set; } = Content;
    public string? Label { get; set; } = Label;
}

/// <summary>Parses raw transcript text into structured blocks. Swift: <c>enum TranscriptBlockParser</c>.</summary>
public static class TranscriptBlockParser
{
    public static IReadOnlyList<TranscriptBlock> Parse(string text)
    {
        var cleaned = StripSystemTags(text);
        if (cleaned.Length == 0)
        {
            return Array.Empty<TranscriptBlock>();
        }

        var blocks = new List<TranscriptBlock>();
        var lines = cleaned.Split('\n');
        int i = 0;

        while (i < lines.Length)
        {
            string line = lines[i];
            string trimmed = line.Trim();

            // Skip empty lines.
            if (trimmed.Length == 0)
            {
                i += 1;
                continue;
            }

            // Separator (--- or === style).
            if (trimmed.Length >= 3 && trimmed.All(c => c == '-' || c == '='))
            {
                blocks.Add(new TranscriptBlock(TranscriptBlockKind.Separator, string.Empty, null));
                i += 1;
                continue;
            }

            // Markdown table — collected then skipped (metadata card owns tables).
            if (trimmed.StartsWith("|", StringComparison.Ordinal) && trimmed.EndsWith("|", StringComparison.Ordinal))
            {
                while (i < lines.Length)
                {
                    string tl = lines[i].Trim();
                    if (!(tl.StartsWith("|", StringComparison.Ordinal) && tl.EndsWith("|", StringComparison.Ordinal)))
                    {
                        break;
                    }

                    i += 1;
                }

                continue;
            }

            // Code block.
            if (trimmed.StartsWith("```", StringComparison.Ordinal))
            {
                string lang = trimmed.Substring(3).Trim();
                i += 1;
                var codeLines = new List<string>();
                while (i < lines.Length)
                {
                    if (lines[i].Trim().StartsWith("```", StringComparison.Ordinal))
                    {
                        i += 1;
                        break;
                    }

                    codeLines.Add(lines[i]);
                    i += 1;
                }

                string code = string.Join("\n", codeLines).Trim('\n', '\r');
                if (code.Length != 0)
                {
                    AppendCodeOrTool(blocks, lang, code);
                }

                continue;
            }

            // H2 headings that indicate the user role.
            if (trimmed.StartsWith("## You", StringComparison.Ordinal)
                || trimmed.StartsWith("## User", StringComparison.Ordinal)
                || trimmed.StartsWith("## Human", StringComparison.Ordinal))
            {
                i += 1;
                var msgLines = new List<string>();
                while (i < lines.Length)
                {
                    string ml = lines[i].Trim();
                    if (ml.StartsWith("## ", StringComparison.Ordinal) || ml.StartsWith("# ", StringComparison.Ordinal))
                    {
                        break;
                    }

                    if (ml.Length >= 3 && ml.All(c => c == '-' || c == '='))
                    {
                        break;
                    }

                    msgLines.Add(lines[i]);
                    i += 1;
                }

                AppendMessage(blocks, TranscriptBlockKind.UserMessage, msgLines);
                continue;
            }

            // H2 headings that indicate the assistant role (with inline code handling).
            if (trimmed.StartsWith("## Assistant", StringComparison.Ordinal)
                || trimmed.StartsWith("## Claude", StringComparison.Ordinal)
                || trimmed.StartsWith("## Response", StringComparison.Ordinal))
            {
                i += 1;
                var msgLines = new List<string>();
                while (i < lines.Length)
                {
                    string ml = lines[i].Trim();
                    if (ml.StartsWith("## ", StringComparison.Ordinal) || ml.StartsWith("# ", StringComparison.Ordinal))
                    {
                        break;
                    }

                    if (ml.Length >= 3 && ml.All(c => c == '-' || c == '=') && !ml.StartsWith("```", StringComparison.Ordinal))
                    {
                        break;
                    }

                    if (ml.StartsWith("```", StringComparison.Ordinal))
                    {
                        // Flush accumulated assistant text before the code block.
                        AppendMessage(blocks, TranscriptBlockKind.AssistantMessage, msgLines);
                        msgLines = new List<string>();

                        string lang = ml.Substring(3).Trim();
                        i += 1;
                        var codeLines = new List<string>();
                        while (i < lines.Length)
                        {
                            if (lines[i].Trim().StartsWith("```", StringComparison.Ordinal))
                            {
                                i += 1;
                                break;
                            }

                            codeLines.Add(lines[i]);
                            i += 1;
                        }

                        string code = string.Join("\n", codeLines).Trim('\n', '\r');
                        if (code.Length != 0)
                        {
                            AppendCodeOrTool(blocks, lang, code);
                        }

                        continue;
                    }

                    msgLines.Add(lines[i]);
                    i += 1;
                }

                AppendMessage(blocks, TranscriptBlockKind.AssistantMessage, msgLines);
                continue;
            }

            // H1 heading — skip (the title is shown in the header).
            if (trimmed.StartsWith("# ", StringComparison.Ordinal))
            {
                i += 1;
                continue;
            }

            // Session Summary heading — skip its content (shown as a card).
            if (trimmed == "## Session Summary")
            {
                i += 1;
                while (i < lines.Length)
                {
                    string sl = lines[i].Trim();
                    if (sl.StartsWith("## ", StringComparison.Ordinal) || sl.StartsWith("# ", StringComparison.Ordinal))
                    {
                        break;
                    }

                    if (sl.Length >= 3 && sl.All(c => c == '-' || c == '='))
                    {
                        break;
                    }

                    i += 1;
                }

                continue;
            }

            // Generic H2 heading — skip.
            if (trimmed.StartsWith("## ", StringComparison.Ordinal))
            {
                i += 1;
                continue;
            }

            // Claude Code raw format: "Human:" / "H:" role markers.
            if (trimmed.StartsWith("Human:", StringComparison.Ordinal) || trimmed.StartsWith("H:", StringComparison.Ordinal))
            {
                string msgStart = trimmed.StartsWith("Human:", StringComparison.Ordinal)
                    ? trimmed.Substring(6)
                    : trimmed.Substring(2);
                var msgLines = new List<string> { msgStart };
                i += 1;
                CollectUntilRoleMarker(lines, ref i, msgLines);
                AppendMessage(blocks, TranscriptBlockKind.UserMessage, msgLines);
                continue;
            }

            if (trimmed.StartsWith("Assistant:", StringComparison.Ordinal) || trimmed.StartsWith("A:", StringComparison.Ordinal))
            {
                string msgStart = trimmed.StartsWith("Assistant:", StringComparison.Ordinal)
                    ? trimmed.Substring(10)
                    : trimmed.Substring(2);
                var msgLines = new List<string> { msgStart };
                i += 1;
                CollectUntilRoleMarker(lines, ref i, msgLines);
                AppendMessage(blocks, TranscriptBlockKind.AssistantMessage, msgLines);
                continue;
            }

            // Plain text — accumulate into an assistant block.
            var plainLines = new List<string> { line };
            i += 1;
            while (i < lines.Length)
            {
                string pl = lines[i].Trim();
                if (pl.StartsWith("## ", StringComparison.Ordinal) || pl.StartsWith("# ", StringComparison.Ordinal))
                {
                    break;
                }

                if (pl.StartsWith("```", StringComparison.Ordinal))
                {
                    break;
                }

                if (pl.StartsWith("|", StringComparison.Ordinal) && pl.EndsWith("|", StringComparison.Ordinal))
                {
                    break;
                }

                if (pl.StartsWith("Human:", StringComparison.Ordinal) || pl.StartsWith("H:", StringComparison.Ordinal))
                {
                    break;
                }

                if (pl.StartsWith("Assistant:", StringComparison.Ordinal) || pl.StartsWith("A:", StringComparison.Ordinal))
                {
                    break;
                }

                if (pl.Length >= 3 && pl.All(c => c == '-' || c == '='))
                {
                    break;
                }

                plainLines.Add(lines[i]);
                i += 1;
            }

            AppendMessage(blocks, TranscriptBlockKind.AssistantMessage, plainLines);
        }

        return blocks;
    }

    /// <summary>Strips XML-like system tags from transcript text.
    /// Swift: <c>static func stripSystemTags(_:)</c>.</summary>
    public static string StripSystemTags(string text)
    {
        string result = text ?? string.Empty;

        result = Regex.Replace(result, "<system-reminder>[\\s\\S]*?</system-reminder>", string.Empty);
        result = Regex.Replace(result, "<local-command-caveat>[\\s\\S]*?</local-command-caveat>", string.Empty);
        result = Regex.Replace(result, "<command-name>[\\s\\S]*?</command-name>", string.Empty);
        result = Regex.Replace(result, "<command-message>[\\s\\S]*?</command-message>", string.Empty);
        result = Regex.Replace(result, "<command-args>[\\s\\S]*?</command-args>", string.Empty);
        result = Regex.Replace(result, "<local-command-stdout>[\\s\\S]*?</local-command-stdout>", string.Empty);
        result = Regex.Replace(result, "</?[a-zA-Z][a-zA-Z0-9_-]*>", string.Empty);
        result = Regex.Replace(result, "\\n{4,}", "\n\n\n");

        return result.Trim();
    }

    private static void CollectUntilRoleMarker(string[] lines, ref int i, List<string> into)
    {
        while (i < lines.Length)
        {
            string ml = lines[i].Trim();
            if (ml.StartsWith("Assistant:", StringComparison.Ordinal) || ml.StartsWith("A:", StringComparison.Ordinal)
                || ml.StartsWith("Human:", StringComparison.Ordinal) || ml.StartsWith("H:", StringComparison.Ordinal))
            {
                break;
            }

            if (ml.StartsWith("## ", StringComparison.Ordinal) || ml.StartsWith("# ", StringComparison.Ordinal))
            {
                break;
            }

            into.Add(lines[i]);
            i += 1;
        }
    }

    private static void AppendCodeOrTool(List<TranscriptBlock> blocks, string lang, string code)
    {
        if (lang == "tool-use" || lang == "tool_use")
        {
            var toolLines = code.Split('\n');
            string toolName = toolLines.Length > 0 ? toolLines[0] : "Tool";
            string detail = string.Join("\n", toolLines.Skip(1)).Trim();
            blocks.Add(new TranscriptBlock(TranscriptBlockKind.ToolUse, detail, toolName));
        }
        else
        {
            blocks.Add(new TranscriptBlock(TranscriptBlockKind.CodeBlock, code, lang.Length == 0 ? null : lang));
        }
    }

    private static void AppendMessage(List<TranscriptBlock> blocks, TranscriptBlockKind kind, List<string> msgLines)
    {
        string msg = string.Join("\n", msgLines).Trim();
        if (msg.Length != 0)
        {
            blocks.Add(new TranscriptBlock(kind, msg, null));
        }
    }
}
