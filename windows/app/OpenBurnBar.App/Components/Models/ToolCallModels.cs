// PORTED (hand-authored, parity-with-Swift) from:
//   OpenBurnBarCore/Sources/OpenBurnBarCore/Views/UnifiedToolCallAccordion.swift
//     — UnifiedToolCallDisplay (state classification, iconName, hasExpandableDetail),
//       UnifiedToolCallAccordion.mostRecent / additionalCount
//
// Pure, platform-agnostic (`System` only) so it compiles + runs on macOS and is asserted
// by windows/tests/components/ToolCallModelTests.cs. The WinUI control
// (Components/UnifiedToolCallAccordion) renders these values.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Components;

/// <summary>Visual state driving the status dot. Swift: <c>UnifiedToolCallDisplay.State</c>.</summary>
public enum ToolCallState
{
    Running,
    Done,
    Failed,
    Neutral,
}

/// <summary>
/// Surface-agnostic description of a single tool invocation. Byte-for-byte port of Swift
/// <c>UnifiedToolCallDisplay</c>: every chat surface maps its native model into this value.
/// </summary>
public sealed class ToolCallDisplay
{
    public string Id { get; }
    public string Name { get; }
    public string? StatusRaw { get; }
    public string? Detail { get; }
    public string? Arguments { get; }
    public string? Result { get; }
    public bool IsRunning { get; }

    public ToolCallDisplay(
        string id,
        string name,
        string? statusRaw = null,
        string? detail = null,
        string? arguments = null,
        string? result = null,
        bool isRunning = false)
    {
        Id = id;
        Name = name;
        StatusRaw = statusRaw;
        Detail = detail;
        Arguments = arguments;
        Result = result;
        IsRunning = isRunning;
    }

    /// <summary>Lenient classification of the runtime's status string. A live call always
    /// wins. Swift: <c>UnifiedToolCallDisplay.state</c>.</summary>
    public ToolCallState State
    {
        get
        {
            if (IsRunning)
            {
                return ToolCallState.Running;
            }

            string raw = (StatusRaw ?? string.Empty).Trim().ToLowerInvariant();
            if (raw.Length == 0)
            {
                return ToolCallState.Neutral;
            }

            if (raw.Contains("fail") || raw.Contains("error") || raw.Contains("denied")
                || raw.Contains("cancel") || raw.Contains("timeout") || raw.Contains("reject"))
            {
                return ToolCallState.Failed;
            }

            if (raw.Contains("done") || raw.Contains("complete") || raw.Contains("finish")
                || raw.Contains("success") || raw.Contains("ok") || raw.Contains("ran"))
            {
                return ToolCallState.Done;
            }

            if (raw.Contains("run") || raw.Contains("pending") || raw.Contains("active")
                || raw.Contains("stream") || raw.Contains("progress") || raw.Contains("start"))
            {
                return ToolCallState.Running;
            }

            return ToolCallState.Neutral;
        }
    }

    /// <summary>Whether expanding reveals more than the collapsed row already shows.
    /// Swift: <c>UnifiedToolCallDisplay.hasExpandableDetail</c>.</summary>
    public bool HasExpandableDetail =>
        !string.IsNullOrWhiteSpace(Arguments) || !string.IsNullOrWhiteSpace(Result);

    /// <summary>Segoe glyph for this tool. Windows stand-in for the SF-Symbol switch in Swift
    /// <c>UnifiedToolCallDisplay.iconName(for:)</c> — same keyword ORDER and matches.</summary>
    public string IconGlyph => IconGlyphFor(Name);

    // Segoe MDL2 Assets / Segoe Fluent Icons codepoints (confident) for the tool families.
    private const string GlyphTerminal = "\uE756";       // CommandPrompt (bash/exec/run)
    private const string GlyphBrain = "\uE99A";          // Robot (memory/skill/learn)
    private const string GlyphPhoto = "\uE8B9";          // Photo (image/vision/screenshot)
    private const string GlyphGlobe = "\uE774";          // Globe (web/browser/fetch/http)
    private const string GlyphSearch = "\uE721";         // Search (search/grep/glob/find)
    private const string GlyphEdit = "\uE70F";           // Edit (edit/patch/replace)
    private const string GlyphDocument = "\uE8A5";       // Document (read/write/file)
    private const string GlyphWrench = "\uE90F";         // Repair (default tool)

    /// <summary>The single canonical tool-name → glyph switch. Swift:
    /// <c>UnifiedToolCallDisplay.iconName(for:)</c> — keyword order is load-bearing.</summary>
    public static string IconGlyphFor(string name)
    {
        string n = (name ?? string.Empty).ToLowerInvariant();
        if (n.Contains("bash") || n.Contains("exec") || n.Contains("terminal")) return GlyphTerminal;
        if (n.Contains("memory") || n.Contains("skill") || n.Contains("learn")) return GlyphBrain;
        if (n.Contains("image") || n.Contains("vision") || n.Contains("screenshot")) return GlyphPhoto;
        if (n.Contains("web") || n.Contains("browser") || n.Contains("fetch") || n.Contains("http")) return GlyphGlobe;
        if (n.Contains("search") || n.Contains("grep") || n.Contains("glob") || n.Contains("find")) return GlyphSearch;
        if (n.Contains("edit") || n.Contains("patch") || n.Contains("replace")) return GlyphEdit;
        if (n.Contains("read") || n.Contains("write") || n.Contains("file")) return GlyphDocument;
        if (n.Contains("run")) return GlyphTerminal;
        return GlyphWrench;
    }
}

/// <summary>Collapsed-by-default disclosure helpers. Swift:
/// <c>UnifiedToolCallAccordion.mostRecent / additionalCount</c>.</summary>
public static class ToolCallAccordionModel
{
    /// <summary>The call shown when collapsed — always the newest (chronological last).</summary>
    public static ToolCallDisplay? MostRecent(IReadOnlyList<ToolCallDisplay> calls) =>
        calls is { Count: > 0 } ? calls[calls.Count - 1] : null;

    /// <summary>How many calls the "+N" badge represents (everything but the newest).</summary>
    public static int AdditionalCount(IReadOnlyList<ToolCallDisplay> calls) =>
        Math.Max(0, (calls?.Count ?? 0) - 1);

    /// <summary>Older calls revealed on expand, newest first.</summary>
    public static IReadOnlyList<ToolCallDisplay> OlderCalls(IReadOnlyList<ToolCallDisplay> calls)
    {
        var result = new List<ToolCallDisplay>();
        if (calls is null || calls.Count <= 1)
        {
            return result;
        }

        for (int i = calls.Count - 2; i >= 0; i--)
        {
            result.Add(calls[i]);
        }

        return result;
    }

    /// <summary>Expansion is worth offering when there is history or the newest call carries
    /// arguments/results beyond its one-line summary.</summary>
    public static bool IsExpandable(IReadOnlyList<ToolCallDisplay> calls) =>
        (calls?.Count ?? 0) > 1 || (MostRecent(calls ?? Array.Empty<ToolCallDisplay>())?.HasExpandableDetail ?? false);
}
