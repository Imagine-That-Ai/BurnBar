using System.Linq;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the kind / depth / approval metadata ported from
/// <c>MissionConsoleKind</c> / <c>MissionConsoleDepth</c> / <c>MissionConsoleApprovalMode</c>.</summary>
public sealed class MissionEnumsTests
{
    [Fact]
    public void Kind_AllEightArchetypesInChooserOrder()
    {
        Assert.Equal(8, MissionKindInfo.All.Count);
        Assert.Equal(MissionKind.Diligence, MissionKindInfo.All[0]);
        Assert.Equal(MissionKind.CostEfficiency, MissionKindInfo.All[^1]);
    }

    [Theory]
    [InlineData(MissionKind.UiImprovement, "ui_improvement")]
    [InlineData(MissionKind.CostEfficiency, "cost_efficiency")]
    [InlineData(MissionKind.Diligence, "diligence")]
    public void Kind_RawValueMatchesSwift(MissionKind kind, string raw) =>
        Assert.Equal(raw, MissionKindInfo.RawValue(kind));

    [Theory]
    [InlineData(MissionKind.Debt, "Debt Sweep")]
    [InlineData(MissionKind.Creative, "Creative Build")]
    [InlineData(MissionKind.UiImprovement, "UI Improvement")]
    public void Kind_DisplayName(MissionKind kind, string display) =>
        Assert.Equal(display, MissionKindInfo.DisplayName(kind));

    [Theory]
    [InlineData(MissionKind.Diligence, 1.20)]
    [InlineData(MissionKind.Creative, 1.35)]
    [InlineData(MissionKind.CostEfficiency, 0.65)]
    [InlineData(MissionKind.Accretive, 0.75)]
    public void Kind_TokenMultiplier(MissionKind kind, double mul) =>
        Assert.Equal(mul, MissionKindInfo.TokenMultiplier(kind), 3);

    [Fact]
    public void Kind_DiligencePrefersClaudeFirst() =>
        Assert.Equal("claude", MissionKindInfo.PreferredRuntimes(MissionKind.Diligence).First());

    [Fact]
    public void Kind_CreativePrefersOpenClawFirst() =>
        Assert.Equal("openclaw", MissionKindInfo.PreferredRuntimes(MissionKind.Creative).First());

    [Fact]
    public void Kind_DebtPrefersCodexFirst() =>
        Assert.Equal("codex", MissionKindInfo.PreferredRuntimes(MissionKind.Debt).First());

    [Fact]
    public void Kind_PreferredRuntimesAlwaysFiveDistinct()
    {
        foreach (MissionKind kind in MissionKindInfo.All)
        {
            var prefs = MissionKindInfo.PreferredRuntimes(kind);
            Assert.Equal(5, prefs.Count);
            Assert.Equal(5, prefs.Distinct().Count());
        }
    }

    [Fact]
    public void Kind_EveryArchetypeHasGlyphAndTagline()
    {
        foreach (MissionKind kind in MissionKindInfo.All)
        {
            Assert.False(string.IsNullOrEmpty(MissionKindInfo.Glyph(kind)));
            Assert.False(string.IsNullOrEmpty(MissionKindInfo.Tagline(kind)));
        }
    }

    [Theory]
    [InlineData(MissionDepth.Light, 0.45)]
    [InlineData(MissionDepth.Standard, 1.00)]
    [InlineData(MissionDepth.Deep, 2.25)]
    public void Depth_Coefficient(MissionDepth depth, double coeff) =>
        Assert.Equal(coeff, MissionDepthInfo.Coefficient(depth), 3);

    [Theory]
    [InlineData(MissionDepth.Light, 0)]
    [InlineData(MissionDepth.Standard, 1)]
    [InlineData(MissionDepth.Deep, 2)]
    public void Depth_Ordinal(MissionDepth depth, int ordinal) =>
        Assert.Equal(ordinal, MissionDepthInfo.Ordinal(depth));

    [Theory]
    [InlineData(MissionApprovalMode.ExistingPolicy, "existing_policy")]
    [InlineData(MissionApprovalMode.RequireApproval, "require_approval")]
    public void ApprovalMode_RawValue(MissionApprovalMode mode, string raw) =>
        Assert.Equal(raw, MissionApprovalModeInfo.RawValue(mode));

    [Fact]
    public void ApprovalMode_HasDistinctCaptions() =>
        Assert.NotEqual(
            MissionApprovalModeInfo.Caption(MissionApprovalMode.ExistingPolicy),
            MissionApprovalModeInfo.Caption(MissionApprovalMode.RequireApproval));
}
