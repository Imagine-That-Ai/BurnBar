using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// Mirrors Swift <c>testGlobalReplacementPlannerDeletesBoundaryCharacterAfterPassThrough</c>
/// and <c>testGlobalTapPolicySkipsOpenBurnBarAndSecureSurfaces</c>.
/// </summary>
public sealed class GlobalReplacementTests
{
    private static TextExpansionMatch AuditMatch(char? boundary)
    {
        var snippet = new TextExpansionSnippet(title: "Audit", trigger: "audit", body: "Audit body");
        return new TextExpansionMatch(
            snippet: snippet,
            token: "&&audit",
            replacementStart: 0,
            replacementEnd: "&&audit".Length,
            boundary: boundary,
            requiresPreview: false);
    }

    [Fact]
    public void Planner_WithBoundary_DeletesTokenPlusBoundary_AndReappendsIt()
    {
        var plan = TextExpansionGlobalReplacementPlanner.PlanFor(AuditMatch(' '));
        Assert.Equal(new TextExpansionGlobalReplacementPlanner.Plan(8, "Audit body "), plan);
    }

    [Fact]
    public void Planner_WithoutBoundary_DeletesExactlyTheToken()
    {
        var plan = TextExpansionGlobalReplacementPlanner.PlanFor(AuditMatch(null));
        Assert.Equal(new TextExpansionGlobalReplacementPlanner.Plan(7, "Audit body"), plan);
    }

    [Fact]
    public void Policy_ShouldIntercept_OnlyWhenEnabledTrustedForeignAndUndenied()
    {
        const string own = "com.openburnbar.app";

        Assert.True(new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: own,
            focusedSurfaceDenied: false).ShouldInterceptKeystrokes);

        // Front app is our own app → do not intercept.
        Assert.False(new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: own,
            ownBundleIdentifier: own,
            focusedSurfaceDenied: false).ShouldInterceptKeystrokes);

        // Focused surface denied (secure field) → do not intercept.
        Assert.False(new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: own,
            focusedSurfaceDenied: true).ShouldInterceptKeystrokes);

        // Feature disabled → do not intercept.
        Assert.False(new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: false,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: own,
            focusedSurfaceDenied: false).ShouldInterceptKeystrokes);

        // Not trusted → do not intercept.
        Assert.False(new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: false,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: own,
            focusedSurfaceDenied: false).ShouldInterceptKeystrokes);
    }
}
