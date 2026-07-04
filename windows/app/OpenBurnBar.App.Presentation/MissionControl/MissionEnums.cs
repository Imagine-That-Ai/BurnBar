using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from OpenBurnBarCore/.../Views/MissionControl/MissionConsoleTypes.swift.
// The three mission-composer axes (kind / depth / approval mode) plus their design
// metadata: display strings, glyphs, forecast multipliers, and the planner's runtime
// preference order. Pure value logic — no SwiftUI, no Windows dependency — so the
// forecast math and the "recommends" hints are unit-testable on the macOS host.

/// <summary>The eight mission archetypes surfaced by the kind chooser. Mirrors
/// <c>MissionConsoleKind</c>.</summary>
public enum MissionKind
{
    Diligence,
    Debt,
    Creative,
    Security,
    Accretive,
    Modernization,
    UiImprovement,
    CostEfficiency,
}

/// <summary>Depth-of-investigation dial. Mirrors <c>MissionConsoleDepth</c>.</summary>
public enum MissionDepth
{
    Light,
    Standard,
    Deep,
}

/// <summary>Approval posture lever. Mirrors <c>MissionConsoleApprovalMode</c>.</summary>
public enum MissionApprovalMode
{
    ExistingPolicy,
    RequireApproval,
}

/// <summary>Planner recommendation the dispatch envelope carries. Mirrors the macOS
/// <c>BurnBarMissionRecommendation</c> arms the console produces.</summary>
public enum MissionRecommendation
{
    Proceed,
    Review,
    Escalate,
}

/// <summary>Design metadata for <see cref="MissionKind"/>. Byte-parity with the Swift
/// <c>MissionConsoleKind</c> computed properties.</summary>
public static class MissionKindInfo
{
    /// <summary>All kinds in chooser order (matches <c>CaseIterable</c>).</summary>
    public static IReadOnlyList<MissionKind> All { get; } = new[]
    {
        MissionKind.Diligence,
        MissionKind.Debt,
        MissionKind.Creative,
        MissionKind.Security,
        MissionKind.Accretive,
        MissionKind.Modernization,
        MissionKind.UiImprovement,
        MissionKind.CostEfficiency,
    };

    /// <summary>Stable lowercase/underscore raw value, matching the Swift <c>rawValue</c>.</summary>
    public static string RawValue(MissionKind kind) => kind switch
    {
        MissionKind.Diligence => "diligence",
        MissionKind.Debt => "debt",
        MissionKind.Creative => "creative",
        MissionKind.Security => "security",
        MissionKind.Accretive => "accretive",
        MissionKind.Modernization => "modernization",
        MissionKind.UiImprovement => "ui_improvement",
        MissionKind.CostEfficiency => "cost_efficiency",
        _ => "diligence",
    };

    public static string DisplayName(MissionKind kind) => kind switch
    {
        MissionKind.Diligence => "Diligence",
        MissionKind.Debt => "Debt Sweep",
        MissionKind.Creative => "Creative Build",
        MissionKind.Security => "Security Audit",
        MissionKind.Accretive => "Accretive Polish",
        MissionKind.Modernization => "Modernization",
        MissionKind.UiImprovement => "UI Improvement",
        MissionKind.CostEfficiency => "Cost Efficiency",
        _ => "Diligence",
    };

    public static string Tagline(MissionKind kind) => kind switch
    {
        MissionKind.Diligence => "Investigate, verify, write the receipts.",
        MissionKind.Debt => "Pay down debt without breaking surfaces.",
        MissionKind.Creative => "Build something new from the brief.",
        MissionKind.Security => "Threat-model the change and prove it.",
        MissionKind.Accretive => "Small wins that compound.",
        MissionKind.Modernization => "Migrate to current platform shape.",
        MissionKind.UiImprovement => "Make the surface delightful.",
        MissionKind.CostEfficiency => "Trim tokens, route smarter.",
        _ => "Investigate, verify, write the receipts.",
    };

    /// <summary>Segoe MDL2 Assets glyph (code point) approximating the macOS SF Symbol.
    /// Exact icon parity is a later design pass; these are stable, existing glyphs.</summary>
    public static string Glyph(MissionKind kind) => kind switch
    {
        MissionKind.Diligence => "",      // magnifyingglass -> Search
        MissionKind.Debt => "",           // wrench.and.screwdriver -> Repair
        MissionKind.Creative => "",       // sparkles -> Light
        MissionKind.Security => "",       // shield -> Lock
        MissionKind.Accretive => "",      // leaf -> FavoriteStar (compounding)
        MissionKind.Modernization => "",  // arrow.up.right -> Up
        MissionKind.UiImprovement => "",  // paintpalette -> Color
        MissionKind.CostEfficiency => "", // gauge -> Battery gauge
        _ => "",
    };

    /// <summary>Runtime preference order — mirrors <c>CLIAgentMissionRuntimePlanner</c>.
    /// Surfaced as the "recommends" hint in the kind chooser.</summary>
    public static IReadOnlyList<string> PreferredRuntimes(MissionKind kind) => kind switch
    {
        MissionKind.Diligence or MissionKind.Security
            => new[] { "claude", "codex", "hermes", "pi", "openclaw" },
        MissionKind.Creative or MissionKind.Accretive or MissionKind.UiImprovement
            => new[] { "openclaw", "codex", "hermes", "pi", "claude" },
        MissionKind.Debt or MissionKind.Modernization or MissionKind.CostEfficiency
            => new[] { "codex", "claude", "hermes", "pi", "openclaw" },
        _ => new[] { "claude", "codex", "hermes", "pi", "openclaw" },
    };

    /// <summary>Multiplier applied to the baseline token forecast.</summary>
    public static double TokenMultiplier(MissionKind kind) => kind switch
    {
        MissionKind.Diligence => 1.20,
        MissionKind.Debt => 0.85,
        MissionKind.Creative => 1.35,
        MissionKind.Security => 1.15,
        MissionKind.Accretive => 0.75,
        MissionKind.Modernization => 1.10,
        MissionKind.UiImprovement => 0.90,
        MissionKind.CostEfficiency => 0.65,
        _ => 1.0,
    };
}

/// <summary>Design metadata for <see cref="MissionDepth"/>. Byte-parity with the Swift
/// <c>MissionConsoleDepth</c>.</summary>
public static class MissionDepthInfo
{
    public static IReadOnlyList<MissionDepth> All { get; } = new[]
    {
        MissionDepth.Light,
        MissionDepth.Standard,
        MissionDepth.Deep,
    };

    public static string DisplayName(MissionDepth depth) => depth switch
    {
        MissionDepth.Light => "Light",
        MissionDepth.Standard => "Standard",
        MissionDepth.Deep => "Deep",
        _ => "Standard",
    };

    public static string Subtitle(MissionDepth depth) => depth switch
    {
        MissionDepth.Light => "Surface-level pass. Fast.",
        MissionDepth.Standard => "Full investigation. Default.",
        MissionDepth.Deep => "Exhaustive. Every thread tied.",
        _ => "Full investigation. Default.",
    };

    /// <summary>Cost coefficient (multiplies tokens x duration).</summary>
    public static double Coefficient(MissionDepth depth) => depth switch
    {
        MissionDepth.Light => 0.45,
        MissionDepth.Standard => 1.00,
        MissionDepth.Deep => 2.25,
        _ => 1.00,
    };

    public static int Ordinal(MissionDepth depth) => depth switch
    {
        MissionDepth.Light => 0,
        MissionDepth.Standard => 1,
        MissionDepth.Deep => 2,
        _ => 1,
    };
}

/// <summary>Design metadata for <see cref="MissionApprovalMode"/>. Byte-parity with the
/// Swift <c>MissionConsoleApprovalMode</c>.</summary>
public static class MissionApprovalModeInfo
{
    public static IReadOnlyList<MissionApprovalMode> All { get; } = new[]
    {
        MissionApprovalMode.ExistingPolicy,
        MissionApprovalMode.RequireApproval,
    };

    public static string RawValue(MissionApprovalMode mode) => mode switch
    {
        MissionApprovalMode.ExistingPolicy => "existing_policy",
        MissionApprovalMode.RequireApproval => "require_approval",
        _ => "existing_policy",
    };

    public static string DisplayName(MissionApprovalMode mode) => mode switch
    {
        MissionApprovalMode.ExistingPolicy => "Honor existing policy",
        MissionApprovalMode.RequireApproval => "Require my approval",
        _ => "Honor existing policy",
    };

    public static string Caption(MissionApprovalMode mode) => mode switch
    {
        MissionApprovalMode.ExistingPolicy => "Use the agent's standard approval rules for shell + edits.",
        MissionApprovalMode.RequireApproval => "Pause mid-flight for every command and edit until I approve.",
        _ => "Use the agent's standard approval rules for shell + edits.",
    };
}
